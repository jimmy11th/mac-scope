from __future__ import annotations

import threading
from datetime import datetime

from conftest import make_process

from macscope.models import (
    CpuMetrics,
    DiskMetrics,
    MemoryMetrics,
    MonitorSnapshot,
    NetworkMetrics,
    Resource,
)
from macscope.service import MonitorService


def make_snapshot(processes) -> MonitorSnapshot:
    return MonitorSnapshot(
        timestamp=datetime.now().astimezone(),
        monotonic_time=1.0,
        cpu=CpuMetrics(20, 10, 10, 80, (1, 1, 1), 8),
        memory=MemoryMetrics(100, 50, 50, 10, 5, 0, 10, 50, "Normal", 50),
        disk=DiskMetrics(100, 40, 60, 40, 1, 2, 3, 4, "/"),
        network=NetworkMetrics("en0", "Wi-Fi", 1, 2, 3, 4),
        processes=tuple(processes),
        cpu_history=(20,),
        memory_history=(50,),
        disk_history=(3,),
        network_history=(3,),
    )


def service_with(processes) -> MonitorService:
    service = MonitorService.__new__(MonitorService)
    service._lock = threading.RLock()
    service._latest = make_snapshot(processes)
    service.show_self = True
    service.include_inactive_io = False
    return service


def test_resource_rankings_use_the_correct_score() -> None:
    low = make_process(pid=1, name="low", cpu_score=2, memory_rss=50, disk_score=9, network_score=1)
    high = make_process(
        pid=2, name="high", cpu_score=9, memory_rss=20, disk_score=1, network_score=7
    )
    service = service_with([low, high])

    assert service.ranked(Resource.CPU)[0].name == "high"
    assert service.ranked(Resource.MEMORY)[0].name == "low"
    assert service.ranked(Resource.DISK)[0].name == "low"
    assert service.ranked(Resource.NETWORK)[0].name == "high"


def test_inactive_io_processes_are_not_reported_as_leaders() -> None:
    inactive = make_process(disk_score=0, network_score=0)
    service = service_with([inactive])

    assert service.ranked(Resource.DISK) == ()
    assert service.ranked(Resource.NETWORK) == ()


def test_process_filter_supports_text_user_and_pid() -> None:
    process = make_process(pid=4242, name="Renderer", username="alice", command="app --render")
    service = service_with([process])

    assert service.all_processes("render") == (process,)
    assert service.all_processes("user:ali") == (process,)
    assert service.all_processes("pid:424") == (process,)
    assert service.all_processes("missing") == ()
