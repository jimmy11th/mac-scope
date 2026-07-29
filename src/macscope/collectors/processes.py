from __future__ import annotations

import math
import time
from dataclasses import replace

import psutil

from macscope.collectors.network import NetTopSampler
from macscope.models import ProcessSample
from macscope.native import LibProc


def exponential_average(
    previous: float | None, current: float, elapsed: float, time_constant: float = 3.0
) -> float:
    if previous is None or time_constant <= 0:
        return current
    alpha = 1.0 - math.exp(-max(0.001, elapsed) / time_constant)
    return previous + alpha * (current - previous)


class ProcessCollector:
    def __init__(self, network: NetTopSampler, libproc: LibProc | None = None) -> None:
        self._network = network
        self._libproc = libproc or LibProc()
        self._last_time = time.monotonic()
        self._disk_previous: dict[tuple[int, float], tuple[int, int]] = {}
        self._memory_previous: dict[tuple[int, float], int] = {}
        self._scores: dict[tuple[int, float], tuple[float, float, float]] = {}
        self._metadata: dict[tuple[int, float], tuple[str, str]] = {}
        self._connection_cache: dict[int, tuple[float, int | None]] = {}
        self.smoothing_seconds = 3.0
        for process in psutil.process_iter():
            try:
                process.cpu_percent(interval=None)
            except (psutil.Error, OSError):
                continue

    def collect(self) -> tuple[tuple[ProcessSample, ...], list[str]]:
        errors: list[str] = []
        now = time.monotonic()
        wall_now = time.time()
        elapsed = max(0.001, now - self._last_time)
        network = self._network.snapshot()
        samples: list[ProcessSample] = []
        live_identities: set[tuple[int, float]] = set()

        attributes = [
            "pid",
            "name",
            "status",
            "memory_info",
            "memory_percent",
            "num_threads",
            "create_time",
        ]
        for process in psutil.process_iter(attributes, ad_value=None):
            try:
                info = process.info
                create_time = float(info["create_time"] or process.create_time())
                identity = (process.pid, create_time)
                live_identities.add(identity)
                cpu_percent = max(0.0, float(process.cpu_percent(interval=None)))
                memory_info = info["memory_info"]
                rss = int(memory_info.rss) if memory_info is not None else 0
                old_rss = self._memory_previous.get(identity)
                memory_growth = ((rss - old_rss) / elapsed) if old_rss is not None else 0.0

                disk = self._libproc.disk_counters(process.pid)
                disk_read_total = disk.read_bytes if disk else 0
                disk_write_total = disk.write_bytes if disk else 0
                old_disk = self._disk_previous.get(identity)
                disk_read_rate = 0.0
                disk_write_rate = 0.0
                if old_disk is not None and disk is not None:
                    disk_read_rate = max(0, disk_read_total - old_disk[0]) / elapsed
                    disk_write_rate = max(0, disk_write_total - old_disk[1]) / elapsed

                net = network.get(process.pid)
                network_download_rate = net.download_rate if net else 0.0
                network_upload_rate = net.upload_rate if net else 0.0
                network_download_total = net.download_total if net else 0
                network_upload_total = net.upload_total if net else 0

                metadata = self._metadata.get(identity)
                if metadata is None:
                    username = "—"
                    command = str(info["name"] or "")
                    try:
                        username = process.username() or "—"
                    except (psutil.Error, OSError):
                        pass
                    try:
                        cmdline = process.cmdline()
                        if cmdline:
                            command = " ".join(cmdline)
                    except (psutil.Error, OSError):
                        pass
                    metadata = (username, command)
                    self._metadata[identity] = metadata

                previous_scores = self._scores.get(identity)
                cpu_score = exponential_average(
                    previous_scores[0] if previous_scores else None,
                    cpu_percent,
                    elapsed,
                    self.smoothing_seconds,
                )
                disk_score = exponential_average(
                    previous_scores[1] if previous_scores else None,
                    disk_read_rate + disk_write_rate,
                    elapsed,
                    self.smoothing_seconds,
                )
                network_score = exponential_average(
                    previous_scores[2] if previous_scores else None,
                    network_download_rate + network_upload_rate,
                    elapsed,
                    self.smoothing_seconds,
                )

                sample = ProcessSample(
                    pid=process.pid,
                    create_time=create_time,
                    name=str(info["name"] or f"PID {process.pid}"),
                    username=metadata[0],
                    command=metadata[1],
                    status=str(info["status"] or "unknown"),
                    cpu_percent=cpu_percent,
                    cpu_score=cpu_score,
                    memory_rss=rss,
                    memory_percent=float(info["memory_percent"] or 0.0),
                    memory_growth=memory_growth,
                    threads=int(info["num_threads"] or 0),
                    elapsed=max(0.0, wall_now - create_time),
                    disk_read_rate=disk_read_rate,
                    disk_write_rate=disk_write_rate,
                    disk_read_total=disk_read_total,
                    disk_write_total=disk_write_total,
                    disk_score=disk_score,
                    network_download_rate=network_download_rate,
                    network_upload_rate=network_upload_rate,
                    network_download_total=network_download_total,
                    network_upload_total=network_upload_total,
                    network_score=network_score,
                )
                samples.append(sample)
                self._disk_previous[identity] = (disk_read_total, disk_write_total)
                self._memory_previous[identity] = rss
                self._scores[identity] = (cpu_score, disk_score, network_score)
            except (psutil.NoSuchProcess, psutil.ZombieProcess):
                continue
            except (psutil.AccessDenied, OSError):
                # Protected macOS processes are expected and simply omitted.
                continue

        network_leaders = sorted(samples, key=lambda item: item.network_score, reverse=True)[:5]
        connection_counts = {
            sample.pid: self._connection_count(sample.pid, now) for sample in network_leaders
        }
        samples = [
            replace(sample, connections=connection_counts.get(sample.pid, sample.connections))
            for sample in samples
        ]

        self._disk_previous = {
            identity: counters
            for identity, counters in self._disk_previous.items()
            if identity in live_identities
        }
        self._memory_previous = {
            identity: rss
            for identity, rss in self._memory_previous.items()
            if identity in live_identities
        }
        self._scores = {
            identity: scores
            for identity, scores in self._scores.items()
            if identity in live_identities
        }
        self._metadata = {
            identity: metadata
            for identity, metadata in self._metadata.items()
            if identity in live_identities
        }
        self._last_time = now
        return tuple(samples), errors

    def set_smoothing(self, seconds: float) -> None:
        seconds = max(0.0, seconds)
        if math.isclose(self.smoothing_seconds, seconds, abs_tol=0.001):
            return
        self.smoothing_seconds = seconds
        self._scores.clear()

    def _connection_count(self, pid: int, now: float) -> int | None:
        cached = self._connection_cache.get(pid)
        if cached is not None and now - cached[0] < 5:
            return cached[1]
        try:
            count = len(psutil.Process(pid).net_connections(kind="inet"))
        except (psutil.NoSuchProcess, psutil.ZombieProcess, psutil.AccessDenied, OSError):
            count = None
        self._connection_cache[pid] = (now, count)
        return count
