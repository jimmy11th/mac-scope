from __future__ import annotations

import pytest
from conftest import make_process

from macscope.i18n import Localizer
from macscope.models import ProcessSort
from macscope.widgets import UnifiedProcessPanel


@pytest.mark.parametrize(
    ("sort_key", "field"),
    [
        (ProcessSort.PID, "pid"),
        (ProcessSort.CPU, "cpu_score"),
        (ProcessSort.MEMORY, "memory_rss"),
        (ProcessSort.DISK_READ, "disk_read_rate"),
        (ProcessSort.DISK_WRITE, "disk_write_rate"),
        (ProcessSort.NETWORK_DOWN, "network_download_rate"),
        (ProcessSort.NETWORK_UP, "network_upload_rate"),
        (ProcessSort.THREADS, "threads"),
        (ProcessSort.RUNTIME, "elapsed"),
    ],
)
def test_unified_process_numeric_sorting(sort_key: ProcessSort, field: str) -> None:
    panel = UnifiedProcessPanel(Localizer())

    def process(name: str, pid: int, value: int):
        values = {"name": name, "pid": pid, field: value}
        return make_process(**values)

    panel._processes = (
        process("one", 10, 10),
        process("two", 30, 30),
        process("three", 20, 20),
    )
    panel.sort_key = sort_key
    panel.descending = True
    panel.include_inactive_io = True

    assert [process.name for process in panel._sorted_processes()] == ["two", "three", "one"]

    panel.descending = False
    assert [process.name for process in panel._sorted_processes()] == ["one", "three", "two"]


def test_unified_process_name_sort_limit_and_inactive_io_filter() -> None:
    panel = UnifiedProcessPanel(Localizer())
    panel._processes = (
        make_process(
            pid=1,
            name="Zulu",
            disk_read_rate=0,
            disk_write_rate=0,
            network_download_rate=0,
            network_upload_rate=0,
        ),
        make_process(
            pid=2,
            name="alpha",
            disk_read_rate=2,
            disk_write_rate=0,
            network_download_rate=4,
            network_upload_rate=0,
        ),
        make_process(
            pid=3,
            name="Bravo",
            disk_read_rate=0,
            disk_write_rate=3,
            network_download_rate=0,
            network_upload_rate=5,
        ),
    )
    panel.top_limit = 2
    panel.include_inactive_io = False

    panel.sort_key = ProcessSort.PROCESS
    panel.descending = False
    assert [process.pid for process in panel._sorted_processes()] == [2, 3]

    panel.sort_key = ProcessSort.DISK_READ
    panel.descending = True
    assert [process.pid for process in panel._sorted_processes()] == [2, 3]

    panel.sort_key = ProcessSort.NETWORK_UP
    assert [process.pid for process in panel._sorted_processes()] == [3, 2]
