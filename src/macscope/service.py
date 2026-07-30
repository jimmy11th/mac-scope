from __future__ import annotations

import threading
import time
from collections import defaultdict, deque
from datetime import datetime

import psutil

from macscope.collectors.network import NetTopSampler
from macscope.collectors.processes import ProcessCollector
from macscope.collectors.system import SystemCollector
from macscope.models import (
    MonitorSnapshot,
    ProcessDetails,
    ProcessHistoryPoint,
    ProcessSample,
    Resource,
)
from macscope.process_guard import protected_pids


class MonitorService:
    def __init__(self) -> None:
        self.network_sampler = NetTopSampler()
        self.system_collector = SystemCollector()
        self.process_collector = ProcessCollector(self.network_sampler)
        self._lock = threading.RLock()
        self._latest: MonitorSnapshot | None = None
        self._system_history: dict[str, deque[float]] = {
            name: deque(maxlen=60) for name in ("cpu", "memory", "disk", "network")
        }
        self._process_history: dict[tuple[int, float], deque[ProcessHistoryPoint]] = defaultdict(
            lambda: deque(maxlen=60)
        )
        self.show_self = True
        self.include_inactive_io = False

    @property
    def latest(self) -> MonitorSnapshot | None:
        with self._lock:
            return self._latest

    def start(self) -> None:
        self.network_sampler.start()

    def stop(self) -> None:
        self.network_sampler.stop()

    def sample(self) -> MonitorSnapshot:
        with self._lock:
            cpu, memory, disk, network, system_errors = self.system_collector.collect()
            processes, process_errors = self.process_collector.collect()
            now = time.monotonic()

            self._system_history["cpu"].append(cpu.percent)
            self._system_history["memory"].append(memory.percent)
            self._system_history["disk"].append(disk.read_rate + disk.write_rate)
            self._system_history["network"].append(network.download_rate + network.upload_rate)

            live_identities: set[tuple[int, float]] = set()
            for process in processes:
                live_identities.add(process.identity)
                self._process_history[process.identity].append(
                    ProcessHistoryPoint(
                        timestamp=now,
                        cpu=process.cpu_percent,
                        memory=process.memory_rss,
                        disk=process.disk_read_rate + process.disk_write_rate,
                        network=process.network_download_rate + process.network_upload_rate,
                    )
                )
            stale = set(self._process_history) - live_identities
            for identity in stale:
                del self._process_history[identity]

            errors = list(system_errors) + list(process_errors)
            if self.network_sampler.error:
                errors.append(self.network_sampler.error)
            snapshot = MonitorSnapshot(
                timestamp=datetime.now().astimezone(),
                monotonic_time=now,
                cpu=cpu,
                memory=memory,
                disk=disk,
                network=network,
                processes=processes,
                cpu_history=tuple(self._system_history["cpu"]),
                memory_history=tuple(self._system_history["memory"]),
                disk_history=tuple(self._system_history["disk"]),
                network_history=tuple(self._system_history["network"]),
                errors=tuple(errors),
            )
            self._latest = snapshot
            return snapshot

    def ranked(
        self, resource: Resource, *, limit: int = 5, filter_text: str = ""
    ) -> tuple[ProcessSample, ...]:
        snapshot = self.latest
        if snapshot is None:
            return ()
        hidden_pids = protected_pids() if not self.show_self else ()
        processes = [
            process
            for process in snapshot.processes
            if self.matches_filter(process, filter_text) and process.pid not in hidden_pids
        ]
        key = {
            Resource.CPU: lambda process: process.cpu_score,
            Resource.MEMORY: lambda process: process.memory_rss,
            Resource.DISK: lambda process: process.disk_score,
            Resource.NETWORK: lambda process: process.network_score,
        }[resource]
        if not self.include_inactive_io and resource in {Resource.DISK, Resource.NETWORK}:
            processes = [process for process in processes if key(process) >= 1.0]
        return tuple(sorted(processes, key=key, reverse=True)[:limit])

    def all_processes(self, query: str = "") -> tuple[ProcessSample, ...]:
        snapshot = self.latest
        if snapshot is None:
            return ()
        hidden_pids = protected_pids() if not self.show_self else ()
        matches = [
            process
            for process in snapshot.processes
            if self.matches_filter(process, query) and process.pid not in hidden_pids
        ]
        return tuple(sorted(matches, key=lambda process: process.cpu_score, reverse=True))

    @staticmethod
    def matches_filter(process: ProcessSample, query: str) -> bool:
        query = query.strip().casefold()
        if not query:
            return True
        if query.startswith("user:"):
            return query[5:].strip() in process.username.casefold()
        if query.startswith("pid:"):
            return query[4:].strip() in str(process.pid)
        haystack = f"{process.name} {process.username} {process.command} {process.pid}".casefold()
        return query in haystack

    def details(self, pid: int) -> ProcessDetails | None:
        with self._lock:
            snapshot = self._latest
            sample = snapshot.process_by_pid(pid) if snapshot is not None else None
            if sample is None:
                return None
            try:
                process = psutil.Process(pid)
                if abs(process.create_time() - sample.create_time) > 0.01:
                    return None
            except (psutil.NoSuchProcess, psutil.ZombieProcess, psutil.AccessDenied):
                return None

            parent_pid: int | None = None
            parent_name = "—"
            executable = "Unavailable"
            cwd = "Unavailable"
            nice: int | None = None
            open_files: tuple[str, ...] = ()
            connections: tuple[str, ...] = ()
            try:
                parent = process.parent()
                if parent is not None:
                    parent_pid = parent.pid
                    parent_name = parent.name()
            except (psutil.Error, OSError):
                pass
            try:
                executable = process.exe() or "Unavailable"
            except (psutil.Error, OSError):
                pass
            try:
                cwd = process.cwd() or "Unavailable"
            except (psutil.Error, OSError):
                pass
            try:
                nice = process.nice()
            except (psutil.Error, OSError):
                pass
            try:
                open_files = tuple(item.path for item in process.open_files()[:12])
            except (psutil.Error, OSError):
                pass
            try:
                connections = tuple(
                    self._format_connection(item)
                    for item in process.net_connections(kind="inet")[:12]
                )
            except (psutil.Error, OSError):
                pass
            return ProcessDetails(
                sample=sample,
                parent_pid=parent_pid,
                parent_name=parent_name,
                executable=executable,
                cwd=cwd,
                nice=nice,
                open_files=open_files,
                connections=connections,
                history=tuple(self._process_history.get(sample.identity, ())),
            )

    def configure(
        self,
        *,
        refresh_interval: float,
        smoothing_seconds: float,
        network_interface: str,
        show_self: bool,
        include_inactive_io: bool,
    ) -> None:
        with self._lock:
            self.network_sampler.set_interval(refresh_interval)
            self.process_collector.set_smoothing(smoothing_seconds)
            self.system_collector.set_network_interface(network_interface)
            self.show_self = show_self
            self.include_inactive_io = include_inactive_io

    @staticmethod
    def _format_connection(connection) -> str:
        def address(value) -> str:
            if not value:
                return "*"
            if hasattr(value, "ip"):
                return f"{value.ip}:{value.port}"
            return ":".join(str(part) for part in value)

        return f"{address(connection.laddr)} → {address(connection.raddr)}  {connection.status}"
