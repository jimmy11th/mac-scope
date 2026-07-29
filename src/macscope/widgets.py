from __future__ import annotations

from rich.console import Group
from rich.table import Table
from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Vertical
from textual.widgets import Button, DataTable, Label, Static

from macscope.formatting import (
    bytes_value,
    clipped,
    duration,
    percent,
    rate,
    sparkline,
    temperature,
)
from macscope.i18n import Localizer
from macscope.models import MonitorSnapshot, ProcessSample, ProcessSort, Resource


def _meter(value: float, color: str, muted: str, width: int = 10) -> Text:
    filled = min(width, max(0, round(value / 100 * width)))
    text = Text()
    text.append("━" * filled, style=f"bold {color}")
    text.append("─" * (width - filled), style=muted)
    return text


class ResourceSummary(Static):
    def __init__(self, resource: Resource, **kwargs) -> None:
        super().__init__(**kwargs)
        self.resource = resource

    def update_snapshot(
        self,
        snapshot: MonitorSnapshot,
        colors: dict[str, str],
        localizer: Localizer,
        temperature_unit: str,
    ) -> None:
        color = colors[self.resource.value]
        title = Text(localizer(f"resource.{self.resource.value}"), style=f"bold {color}")
        if self.resource is Resource.CPU and snapshot.cpu.temperature_celsius is not None:
            temperature_color = {
                "Normal": colors["normal"],
                "Warm": colors["warning"],
                "Hot": colors["danger"],
            }.get(snapshot.cpu.temperature_status, colors["muted"])
            title.append(
                f"   {localizer('summary.soc')} "
                f"{temperature(snapshot.cpu.temperature_celsius, temperature_unit)}",
                style=f"bold {temperature_color}",
            )
        rows = Table.grid(expand=True)
        rows.add_column(ratio=1)
        rows.add_column(justify="right")
        if self.resource is Resource.CPU:
            rows.add_row(
                Text(f"{snapshot.cpu.percent:.1f}%", style=f"bold {colors['text']}"),
                _meter(snapshot.cpu.percent, color, colors["border"]),
            )
            rows.add_row(
                f"{localizer('summary.user')} {snapshot.cpu.user:.1f}%  "
                f"{localizer('summary.system')} {snapshot.cpu.system:.1f}%",
                f"{snapshot.cpu.cores}c",
            )
            rows.add_row(
                f"{localizer('summary.load')} {snapshot.cpu.load[0]:.2f}  "
                f"{snapshot.cpu.load[1]:.2f}",
                sparkline(snapshot.cpu_history),
            )
        elif self.resource is Resource.MEMORY:
            rows.add_row(
                Text(
                    f"{bytes_value(snapshot.memory.used)} / {bytes_value(snapshot.memory.total)}",
                    style=f"bold {colors['text']}",
                ),
                _meter(snapshot.memory.percent, color, colors["border"]),
            )
            rows.add_row(
                f"{localizer('summary.available')} {bytes_value(snapshot.memory.available)}",
                localizer(f"pressure.{snapshot.memory.pressure}"),
            )
            rows.add_row(
                f"{localizer('summary.compressed')} {bytes_value(snapshot.memory.compressed)}",
                f"{localizer('summary.swap')} {bytes_value(snapshot.memory.swap_used)}",
            )
        elif self.resource is Resource.DISK:
            rows.add_row(
                Text(
                    f"{bytes_value(snapshot.disk.used)} / {bytes_value(snapshot.disk.total)}",
                    style=f"bold {colors['text']}",
                ),
                _meter(snapshot.disk.percent, color, colors["border"]),
            )
            rows.add_row(
                f"{localizer('summary.read')} {rate(snapshot.disk.read_rate)}",
                f"{localizer('summary.write')} {rate(snapshot.disk.write_rate)}",
            )
            rows.add_row(
                f"{localizer('summary.free')} {bytes_value(snapshot.disk.free)}",
                sparkline(snapshot.disk_history),
            )
        else:
            rows.add_row(
                Text(snapshot.network.interface_label, style=f"bold {colors['text']}"),
                snapshot.network.interface,
            )
            rows.add_row(
                f"↓ {rate(snapshot.network.download_rate)}",
                f"↑ {rate(snapshot.network.upload_rate)}",
            )
            rows.add_row(
                f"{localizer('summary.total_down')} {bytes_value(snapshot.network.download_total)}",
                sparkline(snapshot.network_history),
            )
        self.update(Group(title, rows))


class UnifiedProcessPanel(Vertical):
    COLUMNS = (
        (ProcessSort.PROCESS, "common.process", 20),
        (ProcessSort.PID, "common.pid", 7),
        (ProcessSort.CPU, "column.cpu", 7),
        (ProcessSort.MEMORY, "column.rss", 10),
        (ProcessSort.DISK_READ, "column.read_rate", 10),
        (ProcessSort.DISK_WRITE, "column.write_rate", 10),
        (ProcessSort.NETWORK_DOWN, "column.down_rate", 10),
        (ProcessSort.NETWORK_UP, "column.up_rate", 10),
        (ProcessSort.THREADS, "column.threads", 8),
        (ProcessSort.RUNTIME, "column.runtime", 10),
    )

    def __init__(
        self,
        localizer: Localizer,
        *,
        sort_key: ProcessSort = ProcessSort.CPU,
        descending: bool = True,
        **kwargs,
    ) -> None:
        super().__init__(**kwargs)
        self.localizer = localizer
        self.pids: list[int] = []
        self.top_limit = 5
        self.sort_key = sort_key
        self.descending = descending
        self.include_inactive_io = False
        self._processes: tuple[ProcessSample, ...] = ()

    def compose(self) -> ComposeResult:
        yield Label(self._title(), classes="panel-title")
        yield DataTable(cursor_type="row", zebra_stripes=True, id="top-processes")
        yield Static(classes="empty-state")

    def on_mount(self) -> None:
        self._configure_columns()

    def set_localizer(self, localizer: Localizer) -> None:
        selected_pid = self.selected_pid
        self.localizer = localizer
        self._configure_columns()
        self._render_rows(selected_pid)

    def _configure_columns(self) -> None:
        table = self.query_one(DataTable)
        table.clear(columns=True)
        for key, label_key, width in self.COLUMNS:
            label = self.localizer(label_key)
            if key is self.sort_key:
                label += " ↓" if self.descending else " ↑"
            table.add_column(label, key=key.value, width=width)

    def _title(self) -> str:
        return self.localizer(
            "panel.unified_top",
            count=self.top_limit,
            column=self.localizer(self._sort_label_key()),
            direction="↓" if self.descending else "↑",
        )

    def update_processes(
        self,
        processes: tuple[ProcessSample, ...],
        *,
        top_limit: int = 5,
        include_inactive_io: bool = False,
    ) -> None:
        selected_pid = self.selected_pid
        self._processes = processes
        self.top_limit = top_limit
        self.include_inactive_io = include_inactive_io
        self._render_rows(selected_pid)

    def set_sort(self, sort_key: ProcessSort, descending: bool | None = None) -> None:
        selected_pid = self.selected_pid
        if descending is not None:
            self.sort_key = sort_key
            self.descending = descending
        elif sort_key is self.sort_key:
            self.descending = not self.descending
        else:
            self.sort_key = sort_key
            self.descending = sort_key is not ProcessSort.PROCESS
        self._configure_columns()
        self._render_rows(selected_pid)

    def on_data_table_header_selected(self, event: DataTable.HeaderSelected) -> None:
        if event.data_table.id == "top-processes":
            self.set_sort(ProcessSort(event.column_key.value))
            event.stop()

    def _render_rows(self, selected_pid: int | None = None) -> None:
        table = self.query_one(DataTable)
        empty_state = self.query_one(".empty-state", Static)
        self.query_one(".panel-title", Label).update(self._title())
        table.clear(columns=False)
        processes = self._sorted_processes()
        self.pids = [process.pid for process in processes]
        table.display = bool(processes)
        empty_state.display = not processes
        if not processes:
            empty_state.update(self.localizer("panel.empty_processes"))
        for process in processes:
            table.add_row(
                clipped(process.name, 20),
                str(process.pid),
                percent(process.cpu_score),
                bytes_value(process.memory_rss),
                rate(process.disk_read_rate),
                rate(process.disk_write_rate),
                rate(process.network_download_rate),
                rate(process.network_upload_rate),
                str(process.threads),
                duration(process.elapsed),
                key=str(process.pid),
            )
        if selected_pid in self.pids:
            table.move_cursor(row=self.pids.index(selected_pid), animate=False)

    def _sorted_processes(self) -> tuple[ProcessSample, ...]:
        processes = list(self._processes)
        if not self.include_inactive_io:
            if self.sort_key in {ProcessSort.DISK_READ, ProcessSort.DISK_WRITE}:
                processes = [
                    process
                    for process in processes
                    if process.disk_read_rate + process.disk_write_rate >= 1.0
                ]
            elif self.sort_key in {ProcessSort.NETWORK_DOWN, ProcessSort.NETWORK_UP}:
                processes = [
                    process
                    for process in processes
                    if process.network_download_rate + process.network_upload_rate >= 1.0
                ]
        key = {
            ProcessSort.PROCESS: lambda process: process.name.casefold(),
            ProcessSort.PID: lambda process: process.pid,
            ProcessSort.CPU: lambda process: process.cpu_score,
            ProcessSort.MEMORY: lambda process: process.memory_rss,
            ProcessSort.DISK_READ: lambda process: process.disk_read_rate,
            ProcessSort.DISK_WRITE: lambda process: process.disk_write_rate,
            ProcessSort.NETWORK_DOWN: lambda process: process.network_download_rate,
            ProcessSort.NETWORK_UP: lambda process: process.network_upload_rate,
            ProcessSort.THREADS: lambda process: process.threads,
            ProcessSort.RUNTIME: lambda process: process.elapsed,
        }[self.sort_key]
        return tuple(sorted(processes, key=key, reverse=self.descending)[: self.top_limit])

    def _sort_label_key(self) -> str:
        return next(label for key, label, _ in self.COLUMNS if key is self.sort_key)

    @property
    def selected_pid(self) -> int | None:
        table = self.query_one(DataTable)
        row = table.cursor_row
        if 0 <= row < len(self.pids):
            return self.pids[row]
        return None


class ToolsPanel(Vertical):
    def __init__(self, localizer: Localizer, **kwargs) -> None:
        super().__init__(**kwargs)
        self.localizer = localizer

    def compose(self) -> ComposeResult:
        yield Label(self.localizer("tools.title"), classes="panel-title")
        yield Button(self.localizer("tools.junk"), id="tool-junk", classes="tool-button")
        yield Button(self.localizer("tools.uninstall"), id="tool-uninstall", classes="tool-button")
        yield Button(self.localizer("tools.memory"), id="tool-memory", classes="tool-button")
        yield Button(
            self.localizer("tools.large_files"), id="tool-large-files", classes="tool-button"
        )
        yield Button(
            self.localizer("tools.duplicates"), id="tool-duplicates", classes="tool-button"
        )

    def set_localizer(self, localizer: Localizer) -> None:
        self.localizer = localizer
        self.query_one(".panel-title", Label).update(localizer("tools.title"))
        labels = {
            "#tool-junk": "tools.junk",
            "#tool-uninstall": "tools.uninstall",
            "#tool-memory": "tools.memory",
            "#tool-large-files": "tools.large_files",
            "#tool-duplicates": "tools.duplicates",
        }
        for selector, key in labels.items():
            self.query_one(selector, Button).label = localizer(key)
