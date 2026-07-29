from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from enum import StrEnum


class Resource(StrEnum):
    CPU = "cpu"
    MEMORY = "memory"
    DISK = "disk"
    NETWORK = "network"


class ProcessSort(StrEnum):
    PROCESS = "process"
    PID = "pid"
    CPU = "cpu"
    MEMORY = "memory"
    DISK_READ = "disk_read"
    DISK_WRITE = "disk_write"
    NETWORK_DOWN = "network_down"
    NETWORK_UP = "network_up"
    THREADS = "threads"
    RUNTIME = "runtime"


@dataclass(frozen=True, slots=True)
class CpuMetrics:
    percent: float
    user: float
    system: float
    idle: float
    load: tuple[float, float, float]
    cores: int
    temperature_celsius: float | None = None
    temperature_status: str = "Unavailable"
    battery_temperature_celsius: float | None = None


@dataclass(frozen=True, slots=True)
class MemoryMetrics:
    total: int
    used: int
    available: int
    cached: int
    compressed: int
    swap_used: int
    swap_total: int
    percent: float
    pressure: str
    headroom_percent: float | None


@dataclass(frozen=True, slots=True)
class DiskMetrics:
    total: int
    used: int
    free: int
    percent: float
    read_rate: float
    write_rate: float
    read_total: int
    write_total: int
    volume: str


@dataclass(frozen=True, slots=True)
class NetworkMetrics:
    interface: str
    interface_label: str
    download_rate: float
    upload_rate: float
    download_total: int
    upload_total: int


@dataclass(frozen=True, slots=True)
class ProcessSample:
    pid: int
    create_time: float
    name: str
    username: str
    command: str
    status: str
    cpu_percent: float
    cpu_score: float
    memory_rss: int
    memory_percent: float
    memory_growth: float
    threads: int
    elapsed: float
    disk_read_rate: float
    disk_write_rate: float
    disk_read_total: int
    disk_write_total: int
    disk_score: float
    network_download_rate: float
    network_upload_rate: float
    network_download_total: int
    network_upload_total: int
    network_score: float
    connections: int | None = None

    @property
    def identity(self) -> tuple[int, float]:
        return (self.pid, self.create_time)


@dataclass(frozen=True, slots=True)
class ProcessHistoryPoint:
    timestamp: float
    cpu: float
    memory: int
    disk: float
    network: float


@dataclass(frozen=True, slots=True)
class ProcessDetails:
    sample: ProcessSample
    parent_pid: int | None
    parent_name: str
    executable: str
    cwd: str
    nice: int | None
    open_files: tuple[str, ...]
    connections: tuple[str, ...]
    history: tuple[ProcessHistoryPoint, ...] = field(default_factory=tuple)


@dataclass(frozen=True, slots=True)
class MonitorSnapshot:
    timestamp: datetime
    monotonic_time: float
    cpu: CpuMetrics
    memory: MemoryMetrics
    disk: DiskMetrics
    network: NetworkMetrics
    processes: tuple[ProcessSample, ...]
    cpu_history: tuple[float, ...]
    memory_history: tuple[float, ...]
    disk_history: tuple[float, ...]
    network_history: tuple[float, ...]
    errors: tuple[str, ...] = field(default_factory=tuple)

    def process_by_pid(self, pid: int) -> ProcessSample | None:
        return next((process for process in self.processes if process.pid == pid), None)


@dataclass(frozen=True, slots=True)
class ActionResult:
    ok: bool
    message: str
