from __future__ import annotations

from typing import ClassVar

from rich.console import Group
from rich.table import Table
from rich.text import Text
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import Button, DataTable, Input, Label, Static

from macscope.formatting import bytes_value, duration, rate, sparkline
from macscope.i18n import Localizer
from macscope.models import ProcessDetails
from macscope.service import MonitorService


class ConfirmScreen(ModalScreen[bool]):
    BINDINGS: ClassVar[list[Binding]] = [
        Binding("y", "confirm", "Confirm", show=False),
        Binding("n", "cancel", "Cancel", show=False),
        Binding("escape", "cancel", "Cancel", show=False),
    ]

    def __init__(self, title: str, message: str, localizer: Localizer | None = None) -> None:
        super().__init__()
        self.dialog_title = title
        self.message = message
        self.localizer = localizer or Localizer()

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog confirm-dialog"):
            yield Label(self.dialog_title, classes="dialog-title")
            yield Label(self.message, classes="dialog-message")
            with Horizontal(classes="dialog-actions"):
                yield Button(self.localizer("common.cancel"), id="cancel")
                yield Button(self.localizer("common.confirm"), variant="error", id="confirm")

    def action_confirm(self) -> None:
        self.dismiss(True)

    def action_cancel(self) -> None:
        self.dismiss(False)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "confirm")


class PromptScreen(ModalScreen[str | None]):
    BINDINGS: ClassVar[list[Binding]] = [Binding("escape", "cancel", "Cancel", show=False)]

    def __init__(
        self,
        title: str,
        placeholder: str,
        value: str = "",
        localizer: Localizer | None = None,
    ) -> None:
        super().__init__()
        self.dialog_title = title
        self.placeholder = placeholder
        self.value = value
        self.localizer = localizer or Localizer()

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog prompt-dialog"):
            yield Label(self.dialog_title, classes="dialog-title")
            yield Input(value=self.value, placeholder=self.placeholder, id="prompt-input")
            with Horizontal(classes="dialog-actions"):
                yield Button(self.localizer("common.cancel"), id="cancel")
                yield Button(self.localizer("common.apply"), variant="primary", id="apply")

    def on_mount(self) -> None:
        self.query_one(Input).focus()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        self.dismiss(event.value.strip())

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "apply":
            self.dismiss(self.query_one(Input).value.strip())
        else:
            self.dismiss(None)

    def action_cancel(self) -> None:
        self.dismiss(None)


class SearchScreen(ModalScreen[int | None]):
    BINDINGS: ClassVar[list[Binding]] = [Binding("escape", "cancel", "Close", show=False)]

    def __init__(self, service: MonitorService, localizer: Localizer | None = None) -> None:
        super().__init__()
        self.service = service
        self.localizer = localizer or Localizer()
        self.pids: list[int] = []

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog search-dialog"):
            yield Label(self.localizer("search.title"), classes="dialog-title")
            yield Input(placeholder=self.localizer("search.prompt"), id="search-input")
            yield DataTable(cursor_type="row", zebra_stripes=True, id="search-results")
            yield Label(self.localizer("search.hint"), classes="dialog-hint")

    def on_mount(self) -> None:
        table = self.query_one(DataTable)
        table.add_columns(
            self.localizer("common.process"),
            self.localizer("common.pid"),
            self.localizer("common.user"),
            self.localizer("column.cpu"),
            self.localizer("resource.memory"),
        )
        self._update_rows("")
        self.query_one(Input).focus()

    def on_input_changed(self, event: Input.Changed) -> None:
        self._update_rows(event.value)

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        if 0 <= event.cursor_row < len(self.pids):
            self.dismiss(self.pids[event.cursor_row])

    def action_cancel(self) -> None:
        self.dismiss(None)

    def _update_rows(self, query: str) -> None:
        table = self.query_one(DataTable)
        table.clear(columns=False)
        processes = self.service.all_processes(query)[:200]
        self.pids = [process.pid for process in processes]
        for process in processes:
            table.add_row(
                process.name[:28],
                str(process.pid),
                process.username[:18],
                f"{process.cpu_percent:.1f}%",
                bytes_value(process.memory_rss),
                key=str(process.pid),
            )


class ProcessDetailsScreen(ModalScreen[None]):
    BINDINGS: ClassVar[list[Binding]] = [
        Binding("escape", "close", "Close", show=False),
        Binding("q", "close", "Close", show=False),
    ]

    def __init__(
        self,
        service: MonitorService,
        pid: int,
        localizer: Localizer | None = None,
        colors: dict[str, str] | None = None,
    ) -> None:
        super().__init__()
        self.service = service
        self.pid = pid
        self.localizer = localizer or Localizer()
        self.theme_colors = colors or {
            "text": "#D7DDE5",
            "muted": "#8994A3",
            "cpu": "#62A8FF",
            "memory": "#58D6A9",
            "disk": "#E5B95C",
            "network": "#EF7BA9",
            "danger": "#FF6B6B",
        }

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog details-dialog"):
            yield Label(self.localizer("details.title"), classes="dialog-title")
            with VerticalScroll():
                yield Static(self.localizer("details.loading"), id="process-details")
            yield Label(self.localizer("common.close_hint"), classes="dialog-hint")

    def on_mount(self) -> None:
        self._refresh_details()
        self.set_interval(1.0, self._refresh_details)

    def action_close(self) -> None:
        self.dismiss(None)

    def _refresh_details(self) -> None:
        details = self.service.details(self.pid)
        target = self.query_one("#process-details", Static)
        if details is None:
            target.update(
                Text(
                    self.localizer("details.exited"),
                    style=f"bold {self.theme_colors['danger']}",
                )
            )
            return
        target.update(self._render_details(details))

    def _render_details(self, details: ProcessDetails) -> Group:
        localizer = self.localizer
        colors = self.theme_colors
        process = details.sample
        summary = Table.grid(padding=(0, 2))
        summary.add_column(style=colors["muted"], width=15)
        summary.add_column(style=colors["text"], overflow="fold")
        summary.add_row(localizer("common.process"), f"{process.name} ({process.pid})")
        summary.add_row(localizer("common.user"), process.username)
        summary.add_row(localizer("details.status"), process.status)
        summary.add_row(
            localizer("details.parent"),
            f"{details.parent_name} ({details.parent_pid or '—'})",
        )
        summary.add_row(localizer("column.runtime"), duration(process.elapsed))
        summary.add_row(
            localizer("details.nice"),
            str(details.nice) if details.nice is not None else localizer("common.unavailable"),
        )
        summary.add_row(localizer("column.threads"), str(process.threads))
        summary.add_row(localizer("details.command"), process.command or "—")
        summary.add_row(localizer("details.executable"), details.executable)
        summary.add_row(localizer("details.cwd"), details.cwd)

        resources = Table.grid(padding=(0, 2))
        resources.add_column(style=colors["muted"], width=15)
        resources.add_column(style=colors["text"])
        resources.add_row(localizer("resource.cpu"), f"{process.cpu_percent:.1f}%")
        resources.add_row(
            localizer("resource.memory"),
            f"{bytes_value(process.memory_rss)}  ({process.memory_percent:.1f}%)",
        )
        resources.add_row(
            localizer("resource.disk"),
            f"↓ {rate(process.disk_read_rate)}  ↑ {rate(process.disk_write_rate)}",
        )
        resources.add_row(
            localizer("details.disk_total"),
            bytes_value(process.disk_read_total + process.disk_write_total),
        )
        resources.add_row(
            localizer("resource.network"),
            f"↓ {rate(process.network_download_rate)}  ↑ {rate(process.network_upload_rate)}",
        )
        resources.add_row(
            localizer("details.network_total"),
            bytes_value(process.network_download_total + process.network_upload_total),
        )

        cpu = tuple(point.cpu for point in details.history)
        memory = tuple(float(point.memory) for point in details.history)
        disk = tuple(point.disk for point in details.history)
        network = tuple(point.network for point in details.history)
        trends = Table.grid(padding=(0, 2))
        trends.add_column(style=colors["muted"], width=15)
        trends.add_column()
        trends.add_row("CPU · 60s", Text(sparkline(cpu, width=36), style=colors["cpu"]))
        trends.add_row(
            f"{localizer('resource.memory')} · 60s",
            Text(sparkline(memory, width=36), style=colors["memory"]),
        )
        trends.add_row(
            f"{localizer('resource.disk')} · 60s",
            Text(sparkline(disk, width=36), style=colors["disk"]),
        )
        trends.add_row(
            f"{localizer('resource.network')} · 60s",
            Text(sparkline(network, width=36), style=colors["network"]),
        )

        files = "\n".join(details.open_files) if details.open_files else localizer("details.none")
        connections = (
            "\n".join(details.connections) if details.connections else localizer("details.none")
        )
        return Group(
            summary,
            Text(f"\n{localizer('details.live')}", style=f"bold {colors['text']}"),
            resources,
            Text(f"\n{localizer('details.trends')}", style=f"bold {colors['text']}"),
            trends,
            Text(f"\n{localizer('details.files')}", style=f"bold {colors['text']}"),
            Text(files, style=colors["muted"]),
            Text(f"\n{localizer('details.connections')}", style=f"bold {colors['text']}"),
            Text(connections, style=colors["muted"]),
        )


class HelpScreen(ModalScreen[None]):
    BINDINGS: ClassVar[list[Binding]] = [
        Binding("escape", "close", "Close", show=False),
        Binding("q", "close", "Close", show=False),
        Binding("question_mark", "close", "Close", show=False),
    ]

    def __init__(self, localizer: Localizer | None = None) -> None:
        super().__init__()
        self.localizer = localizer or Localizer()

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog help-dialog"):
            yield Label(self.localizer("help.title"), classes="dialog-title")
            yield Static(self.localizer("help.content"))
            yield Label(self.localizer("common.close_hint"), classes="dialog-hint")

    def action_close(self) -> None:
        self.dismiss(None)
