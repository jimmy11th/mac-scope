from __future__ import annotations

import os
import re
import shutil
import subprocess
import time
from pathlib import Path

import psutil

from macscope.models import CpuMetrics, DiskMetrics, MemoryMetrics, NetworkMetrics
from macscope.native import IOHIDTemperatureReader, TemperatureReadings

_PERCENT_PATTERN = re.compile(r"free percentage:\s*(\d+(?:\.\d+)?)%", re.IGNORECASE)
_PAGE_SIZE_PATTERN = re.compile(r"page size of\s+(\d+)\s+bytes")
_COMPRESSED_PATTERN = re.compile(r"Pages occupied by compressor:\s+(\d+)\.")


def parse_memory_pressure(output: str) -> float | None:
    match = _PERCENT_PATTERN.search(output)
    return float(match.group(1)) if match else None


def pressure_label(headroom: float | None) -> str:
    if headroom is None or headroom >= 20:
        return "Normal"
    if headroom >= 10:
        return "Warning"
    return "Critical"


def parse_compressed_memory(output: str) -> int:
    size_match = _PAGE_SIZE_PATTERN.search(output)
    pages_match = _COMPRESSED_PATTERN.search(output)
    if not size_match or not pages_match:
        return 0
    return int(size_match.group(1)) * int(pages_match.group(1))


def temperature_label(celsius: float | None) -> str:
    if celsius is None:
        return "Unavailable"
    if celsius < 80:
        return "Normal"
    if celsius < 95:
        return "Warm"
    return "Hot"


class SystemCollector:
    def __init__(self) -> None:
        self._last_time = time.monotonic()
        self._last_disk = psutil.disk_io_counters()
        self._interface = self._default_interface()
        self._interface_label = self._hardware_port(self._interface)
        self._last_network = self._network_counters()
        self._slow_updated = 0.0
        self._temperature_updated = 0.0
        self._headroom: float | None = None
        self._compressed = 0
        self._temperatures = TemperatureReadings(None, None, None, "", None)
        try:
            self._temperature_reader: IOHIDTemperatureReader | None = IOHIDTemperatureReader()
        except OSError:
            self._temperature_reader = None
        psutil.cpu_times_percent(interval=None)

    @property
    def interface(self) -> str:
        return self._interface

    def set_network_interface(self, interface: str) -> None:
        selected = self._default_interface() if interface == "auto" else interface
        if selected == self._interface:
            return
        self._interface = selected
        self._interface_label = self._hardware_port(selected)
        self._last_network = self._network_counters()

    def collect(
        self,
    ) -> tuple[CpuMetrics, MemoryMetrics, DiskMetrics, NetworkMetrics, list[str]]:
        errors: list[str] = []
        now = time.monotonic()
        cpu_interval = 0.1 if now - self._last_time < 0.1 else None
        cpu_times = psutil.cpu_times_percent(interval=cpu_interval)
        now = time.monotonic()
        elapsed = max(0.001, now - self._last_time)
        if now - self._temperature_updated >= 2:
            self._update_temperatures(errors)
            self._temperature_updated = now
        load = os.getloadavg()
        cpu = CpuMetrics(
            percent=max(0.0, 100.0 - float(cpu_times.idle)),
            user=float(cpu_times.user),
            system=float(cpu_times.system),
            idle=float(cpu_times.idle),
            load=(float(load[0]), float(load[1]), float(load[2])),
            cores=psutil.cpu_count(logical=True) or 1,
            temperature_celsius=self._temperatures.soc_celsius,
            temperature_status=temperature_label(self._temperatures.soc_celsius),
            battery_temperature_celsius=self._temperatures.battery_celsius,
        )

        if now - self._slow_updated >= 5:
            self._update_slow_memory_metrics(errors)
            self._slow_updated = now
        virtual = psutil.virtual_memory()
        swap = psutil.swap_memory()
        cached = int(getattr(virtual, "inactive", 0))
        memory = MemoryMetrics(
            total=int(virtual.total),
            used=int(virtual.used),
            available=int(virtual.available),
            cached=cached,
            compressed=self._compressed,
            swap_used=int(swap.used),
            swap_total=int(swap.total),
            percent=float(virtual.percent),
            pressure=pressure_label(self._headroom),
            headroom_percent=self._headroom,
        )

        volume_path = Path("/System/Volumes/Data")
        if not volume_path.exists():
            volume_path = Path("/")
        usage = shutil.disk_usage(volume_path)
        current_disk = psutil.disk_io_counters()
        disk_read_rate = 0.0
        disk_write_rate = 0.0
        if current_disk is not None and self._last_disk is not None:
            disk_read_rate = max(0, current_disk.read_bytes - self._last_disk.read_bytes) / elapsed
            disk_write_rate = (
                max(0, current_disk.write_bytes - self._last_disk.write_bytes) / elapsed
            )
        disk = DiskMetrics(
            total=usage.total,
            used=usage.used,
            free=usage.free,
            percent=(usage.used / usage.total * 100.0) if usage.total else 0.0,
            read_rate=disk_read_rate,
            write_rate=disk_write_rate,
            read_total=int(current_disk.read_bytes) if current_disk else 0,
            write_total=int(current_disk.write_bytes) if current_disk else 0,
            volume=str(volume_path),
        )

        current_network = self._network_counters()
        download_rate = 0.0
        upload_rate = 0.0
        if current_network is not None and self._last_network is not None:
            download_rate = (
                max(0, current_network.bytes_recv - self._last_network.bytes_recv) / elapsed
            )
            upload_rate = (
                max(0, current_network.bytes_sent - self._last_network.bytes_sent) / elapsed
            )
        network = NetworkMetrics(
            interface=self._interface,
            interface_label=self._interface_label,
            download_rate=download_rate,
            upload_rate=upload_rate,
            download_total=int(current_network.bytes_recv) if current_network else 0,
            upload_total=int(current_network.bytes_sent) if current_network else 0,
        )

        self._last_time = now
        self._last_disk = current_disk
        self._last_network = current_network
        return cpu, memory, disk, network, errors

    def _network_counters(self):
        counters = psutil.net_io_counters(pernic=True)
        if self._interface in counters:
            return counters[self._interface]
        usable = [
            value
            for name, value in counters.items()
            if name != "lo0" and not name.startswith(("awdl", "llw", "utun"))
        ]
        if not usable:
            return None
        fields = type(usable[0])
        return fields(
            *(sum(getattr(item, field) for item in usable) for field in usable[0]._fields)
        )

    def _update_slow_memory_metrics(self, errors: list[str]) -> None:
        try:
            result = subprocess.run(
                ["/usr/bin/memory_pressure", "-Q"],
                capture_output=True,
                text=True,
                timeout=1,
                check=False,
            )
            self._headroom = parse_memory_pressure(result.stdout)
        except (OSError, subprocess.TimeoutExpired) as exc:
            errors.append(f"Memory pressure unavailable: {exc}")
        try:
            result = subprocess.run(
                ["/usr/bin/vm_stat"],
                capture_output=True,
                text=True,
                timeout=1,
                check=False,
            )
            self._compressed = parse_compressed_memory(result.stdout)
        except (OSError, subprocess.TimeoutExpired) as exc:
            errors.append(f"Compressed memory unavailable: {exc}")

    def _update_temperatures(self, errors: list[str]) -> None:
        if self._temperature_reader is None:
            return
        try:
            self._temperatures = self._temperature_reader.read()
        except (OSError, ValueError) as exc:
            errors.append(f"Temperature sensors unavailable: {exc}")

    @staticmethod
    def _default_interface() -> str:
        try:
            result = subprocess.run(
                ["/sbin/route", "-n", "get", "default"],
                capture_output=True,
                text=True,
                timeout=1,
                check=False,
            )
            for line in result.stdout.splitlines():
                if line.strip().startswith("interface:"):
                    return line.split(":", 1)[1].strip()
        except (OSError, subprocess.TimeoutExpired):
            pass
        return "en0"

    @staticmethod
    def _hardware_port(interface: str) -> str:
        try:
            result = subprocess.run(
                ["/usr/sbin/networksetup", "-listallhardwareports"],
                capture_output=True,
                text=True,
                timeout=1,
                check=False,
            )
            blocks = result.stdout.split("\n\n")
            for block in blocks:
                if f"Device: {interface}" in block:
                    first_line = block.splitlines()[0]
                    return first_line.split(":", 1)[-1].strip()
        except (OSError, subprocess.TimeoutExpired):
            pass
        return interface
