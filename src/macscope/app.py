from __future__ import annotations

import asyncio
from dataclasses import replace
from typing import ClassVar

import psutil
from textual import events
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Grid
from textual.timer import Timer
from textual.widgets import Button, DataTable, Footer, Header, Static, Tab, Tabs

from macscope.actions import ProcessController
from macscope.i18n import Localizer
from macscope.maintenance import MaintenanceService
from macscope.maintenance_screens import MaintenanceScreen, MemoryReliefScreen
from macscope.models import ActionResult, MonitorSnapshot, ProcessSample, ProcessSort, Resource
from macscope.preferences import SettingsScreen
from macscope.screens import (
    ConfirmScreen,
    HelpScreen,
    ProcessDetailsScreen,
    PromptScreen,
    SearchScreen,
)
from macscope.service import MonitorService
from macscope.settings import Settings, SettingsStore, resolve_scan_roots, validate_settings
from macscope.themes import ThemeRepository, textual_theme_from_colors
from macscope.widgets import ResourceSummary, ToolsPanel, UnifiedProcessPanel


class MacScopeApp(App[None]):
    TITLE = "MacScope"
    SUB_TITLE = "macOS system monitor"

    CSS = """
    Screen {
        background: $background;
        color: $foreground;
    }

    Header {
        background: $surface;
        color: $foreground;
    }

    #overview {
        layout: grid;
        grid-size: 4 1;
        grid-columns: 1fr;
        grid-rows: 1fr;
        grid-gutter: 0 1;
        height: 8;
        padding: 0 1;
    }

    ResourceSummary {
        height: 8;
        padding: 1;
        background: $surface;
        border-top: solid $border;
    }

    #resource-cpu { border-top: solid $cpu; }
    #resource-memory { border-top: solid $memory; }
    #resource-disk { border-top: solid $disk; }
    #resource-network { border-top: solid $network; }

    #view-tabs {
        display: none;
    }

    #workspace {
        layout: grid;
        grid-size: 2 1;
        grid-columns: 3fr 1fr;
        grid-rows: 1fr;
        grid-gutter: 0 1;
        height: 1fr;
        padding: 0 1;
    }

    UnifiedProcessPanel,
    ToolsPanel {
        background: $surface-alt;
        border: solid $border;
        min-height: 9;
    }

    UnifiedProcessPanel:focus-within,
    ToolsPanel:focus-within {
        border: solid $focus;
    }

    .panel-title {
        height: 2;
        padding: 0 1;
        color: $accent;
        text-style: bold;
        content-align: left middle;
    }

    UnifiedProcessPanel DataTable {
        height: 1fr;
        background: $surface-alt;
        color: $foreground;
    }

    UnifiedProcessPanel DataTable > .datatable--header {
        background: $surface;
        color: $muted;
        text-style: bold;
    }

    UnifiedProcessPanel DataTable > .datatable--cursor {
        background: $selection;
        color: $selection-text;
    }

    ToolsPanel {
        padding: 0 1;
    }

    .tool-button.-style-default {
        width: 100%;
        height: 3;
        margin-bottom: 1;
        color: $foreground;
        background: $surface;
        border: none;
        text-align: left;
        content-align: left middle;
    }

    .tool-button.-style-default:hover,
    .tool-button.-style-default:focus {
        color: $selection-text;
        background: $accent;
        border: none;
    }

    .empty-state {
        display: none;
        height: 1fr;
        color: $muted;
        content-align: center middle;
    }

    #status-line {
        height: 1;
        padding: 0 2;
        color: $muted;
        background: $background;
    }

    Footer {
        background: $surface;
    }

    Screen.compact #overview {
        grid-size: 2 2;
        grid-columns: 1fr 1fr;
        grid-rows: 1fr 1fr;
        height: 14;
    }

    Screen.compact ResourceSummary {
        height: 7;
        padding: 0 1;
    }

    Screen.compact #view-tabs {
        display: block;
        height: 3;
        margin: 0 1;
    }

    Screen.compact #workspace {
        grid-size: 1 1;
        grid-columns: 1fr;
        grid-rows: 1fr;
    }

    Screen.compact UnifiedProcessPanel,
    Screen.compact ToolsPanel {
        display: none;
    }

    Screen.compact .active-view {
        display: block;
    }

    Screen.compact .tool-button.-style-default {
        margin-bottom: 0;
    }

    ModalScreen {
        align: center middle;
        background: rgba(4, 6, 9, 0.78);
    }

    .dialog {
        width: 72;
        max-width: 92%;
        height: auto;
        max-height: 92%;
        padding: 1 2;
        background: $surface;
        border: solid $border;
    }

    .dialog-title {
        height: 2;
        color: $foreground;
        text-style: bold;
    }

    .dialog-message {
        height: auto;
        margin-bottom: 1;
        color: $foreground;
    }

    .dialog Button.-style-default {
        height: 3;
        color: $foreground;
        background: $surface-alt;
        border: none;
        text-style: bold;
        content-align: center middle;
    }

    .dialog Button.-style-default:hover,
    .dialog Button.-style-default:focus {
        color: $foreground;
        background: $selection;
        border: none;
    }

    .dialog Button.-style-default.-active {
        color: $selection-text;
        background: $focus;
        border: none;
        tint: transparent;
    }

    .dialog Button.-style-default.-primary {
        color: $selection-text;
        background: $accent;
        border: none;
    }

    .dialog Button.-style-default.-primary:hover,
    .dialog Button.-style-default.-primary:focus {
        color: $selection-text;
        background: $focus;
        border: none;
    }

    .dialog Button.-style-default.-error {
        color: $selection-text;
        background: $error;
        border: none;
    }

    .dialog Button.-style-default.-error:hover,
    .dialog Button.-style-default.-error:focus {
        color: $selection-text;
        background: $error;
        border: none;
        text-style: bold underline;
    }

    .dialog-actions {
        height: 3;
        align-horizontal: right;
        margin-top: 1;
    }

    .dialog-actions Button {
        min-width: 12;
        margin-left: 1;
    }

    .prompt-dialog Input {
        margin: 1 0;
    }

    .search-dialog {
        width: 104;
        height: 82%;
    }

    .search-dialog Input {
        margin-bottom: 1;
    }

    #search-results {
        height: 1fr;
    }

    .details-dialog {
        width: 104;
        height: 88%;
    }

    .details-dialog VerticalScroll {
        height: 1fr;
        padding: 0 1;
    }

    .dialog-hint {
        height: 1;
        color: $muted;
        text-align: right;
    }

    .help-dialog {
        width: 66;
    }

    .settings-dialog {
        width: 86;
        height: 90%;
    }

    .settings-body {
        height: 1fr;
        padding: 0 1;
    }

    .settings-section {
        height: 2;
        margin-top: 1;
        color: $accent;
        text-style: bold;
    }

    .preference-row {
        height: 3;
        align-vertical: middle;
    }

    .preference-label {
        width: 1fr;
        color: $foreground;
    }

    .preference-row Select,
    .preference-row Input {
        width: 34;
    }

    Select > SelectCurrent {
        color: $foreground;
        background: $surface-alt;
        border: none;
        padding: 0 1;
    }

    Select:focus > SelectCurrent {
        color: $accent;
        background: $surface-alt;
        background-tint: transparent;
        border-left: solid $accent;
    }

    Select > SelectOverlay,
    Select > SelectOverlay:focus {
        color: $foreground;
        background: $surface;
        background-tint: transparent;
        border: solid $border;
    }

    Select > SelectOverlay > .option-list--option-highlighted,
    Select > SelectOverlay:focus > .option-list--option-highlighted {
        color: $selection-text;
        background: $selection;
        text-style: none;
    }

    Select > SelectOverlay > .option-list--option-hover {
        background: $surface-alt;
    }

    .scan-roots-row Input {
        width: 50;
    }

    .preference-row Switch {
        width: 8;
        height: 1;
        margin-right: 3;
        padding: 0;
        border: none;
        background: transparent;
    }

    .preference-row Switch > .switch--slider {
        color: $muted;
        background: $border;
    }

    .preference-row Switch.-on > .switch--slider {
        color: $accent;
        background: $border;
    }

    .preference-row Switch:hover > .switch--slider {
        color: $foreground;
        background: $border;
    }

    .preference-row Switch.-on:hover > .switch--slider {
        color: $accent;
        background: $focus;
    }

    .preference-row Switch:focus {
        border: none;
        background: transparent;
    }

    .theme-actions {
        height: 3;
        align-horizontal: right;
    }

    .theme-actions Button {
        min-width: 12;
        margin-left: 1;
    }

    .settings-actions Button:first-child {
        margin-right: 1;
    }

    .theme-editor-dialog {
        width: 92;
        height: 92%;
    }

    .theme-meta-row Input {
        width: 1fr;
        margin-right: 1;
    }

    .theme-meta-row Select {
        width: 18;
    }

    #contrast-status {
        height: 2;
        color: $muted;
        text-align: right;
    }

    .theme-color-list {
        height: 1fr;
    }

    .color-row {
        height: 3;
        align-vertical: middle;
    }

    .color-label {
        width: 30;
        color: $foreground;
    }

    .color-swatch {
        width: 6;
        height: 1;
        margin-right: 2;
    }

    .color-row Input {
        width: 1fr;
    }

    .maintenance-dialog {
        width: 112;
        height: 88%;
    }

    .maintenance-summary {
        height: 2;
        color: $muted;
    }

    #maintenance-progress,
    #uninstall-progress {
        display: none;
        width: 100%;
        height: 1;
        margin-bottom: 1;
        color: $accent;
    }

    #maintenance-progress.active,
    #uninstall-progress.active {
        display: block;
    }

    #maintenance-current,
    #uninstall-current {
        display: none;
        height: 2;
        color: $muted;
    }

    #maintenance-current.active,
    #uninstall-current.active {
        display: block;
    }

    .uninstall-dialog {
        width: 108;
        height: 86%;
    }

    #uninstall-app-summary {
        height: 3;
        padding: 0 1;
        color: $foreground;
        background: $surface-alt;
        content-align: left middle;
    }

    #uninstall-copy-warning {
        display: none;
        height: auto;
        max-height: 4;
        margin: 1 0;
        color: $warning;
    }

    #uninstall-copy-warning.visible {
        display: block;
    }

    #uninstall-items {
        height: 1fr;
        color: $foreground;
        background: $surface-alt;
    }

    #uninstall-items > .datatable--header {
        color: $muted;
        background: $surface;
        text-style: bold;
    }

    #uninstall-items > .datatable--cursor {
        color: $selection-text;
        background: $selection;
        text-style: none;
    }

    #maintenance-status {
        width: 1fr;
    }

    #maintenance-total {
        width: auto;
        text-align: right;
        color: $foreground;
    }

    #maintenance-results,
    #memory-processes {
        height: 1fr;
        background: $surface-alt;
        color: $foreground;
    }

    #maintenance-results > .datatable--header,
    #memory-processes > .datatable--header {
        background: $surface;
        color: $muted;
        text-style: bold;
    }

    #maintenance-results > .datatable--cursor,
    #memory-processes > .datatable--cursor {
        background: $selection;
        color: $selection-text;
    }

    .maintenance-actions {
        width: 100%;
    }

    #maintenance-select-all {
        min-width: 16;
    }

    .memory-dialog {
        width: 96;
        height: 82%;
    }

    #memory-summary {
        height: 3;
        padding: 0 1;
        color: $foreground;
        background: $surface-alt;
        content-align: left middle;
    }

    Screen.compact .maintenance-dialog,
    Screen.compact .memory-dialog {
        width: 96%;
        height: 92%;
        padding: 1;
    }

    Screen.compact .maintenance-summary {
        layout: vertical;
        height: 4;
    }

    Screen.compact #maintenance-status {
        width: 100%;
        height: 2;
    }

    Screen.compact #maintenance-total {
        width: 100%;
        height: 1;
        text-align: left;
    }
    """

    BINDINGS: ClassVar[list[Binding]] = [
        Binding("q", "quit", "Quit"),
        Binding("slash", "search", "Search"),
        Binding("f", "filter", "Filter"),
        Binding("t", "terminate", "Terminate"),
        Binding("k", "kill", "Kill"),
        Binding("space", "toggle_process", "Pause/resume"),
        Binding("r", "change_priority", "Priority"),
        Binding("s", "settings", "Settings"),
        Binding("l", "top_limit", "Rows"),
        Binding("plus", "increase_top", "More rows", show=False),
        Binding("equal", "increase_top", "More rows", show=False),
        Binding("minus", "decrease_top", "Fewer rows", show=False),
        Binding("p", "toggle_monitoring", "Pause monitor"),
        Binding("question_mark", "help", "Help"),
        Binding("1", "focus_cpu", "CPU", show=False),
        Binding("2", "focus_memory", "Memory", show=False),
        Binding("3", "focus_disk", "Disk", show=False),
        Binding("4", "focus_network", "Network", show=False),
    ]

    def __init__(
        self,
        *,
        settings_store: SettingsStore | None = None,
        settings: Settings | None = None,
    ) -> None:
        super().__init__()
        self.settings_store = settings_store or SettingsStore()
        self.settings = validate_settings(settings or self.settings_store.load())
        self.theme_repository = ThemeRepository(self.settings_store.data_directory / "themes")
        if not self.theme_repository.exists(self.settings.theme):
            self.settings = self.settings.with_overrides(theme="graphite-dark")
        self.localizer = Localizer(self.settings.language)
        self._localize_bindings(refresh=False)
        self.sub_title = self.localizer("app.subtitle")
        for definition in self.theme_repository.all():
            try:
                self.register_theme(self.theme_repository.textual_theme(definition.id))
            except ValueError:
                continue
        self.current_theme_id = self.settings.theme
        self.theme_colors = self.theme_repository.resolved_colors(self.current_theme_id)
        self.theme = self.theme_repository.textual_name(self.current_theme_id)
        self.service = MonitorService()
        self.service.configure(
            refresh_interval=self.settings.refresh_interval,
            smoothing_seconds=self.settings.smoothing_seconds,
            network_interface=self.settings.network_interface,
            show_self=self.settings.show_self,
            include_inactive_io=self.settings.include_inactive_io,
        )
        self.controller = ProcessController(self.localizer)
        self.maintenance = MaintenanceService(scan_roots=resolve_scan_roots(self.settings))
        self.filter_text = ""
        self.top_limit = self.settings.default_top_rows
        self.monitoring_paused = False
        self._collecting = False
        self._refresh_timer: Timer | None = None
        self._last_selected_pid: int | None = None
        self._active_view = "top"

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with Grid(id="overview"):
            for resource in Resource:
                yield ResourceSummary(resource, id=f"resource-{resource.value}")
        yield Tabs(
            Tab(self.localizer("view.top"), id="tab-top"),
            Tab(self.localizer("view.tools"), id="tab-tools"),
            id="view-tabs",
        )
        with Grid(id="workspace"):
            yield UnifiedProcessPanel(
                self.localizer,
                sort_key=ProcessSort(self.settings.default_sort_key),
                descending=self.settings.default_sort_descending,
                id="process-panel",
                classes="active-view",
            )
            yield ToolsPanel(self.localizer, id="tools-panel")
        yield Static(self.localizer("status.starting"), id="status-line")
        yield Footer()

    async def on_mount(self) -> None:
        self.service.start()
        self.query_one("#view-tabs", Tabs).can_focus = False
        self._set_responsive_state(self.size.width)
        await self._collect_once()
        self._refresh_timer = self.set_interval(self.settings.refresh_interval, self._collect_once)
        self.query_one("#process-panel", UnifiedProcessPanel).query_one(DataTable).focus()

    def on_unmount(self) -> None:
        self.service.stop()

    def on_resize(self, event: events.Resize) -> None:
        self._set_responsive_state(event.size.width)

    def on_tabs_tab_activated(self, event: Tabs.TabActivated) -> None:
        if event.tabs.id != "view-tabs" or event.tab.id is None:
            return
        self._activate_view(event.tab.id.removeprefix("tab-"))

    def on_data_table_row_highlighted(self, event: DataTable.RowHighlighted) -> None:
        panel = event.data_table.parent
        if isinstance(panel, UnifiedProcessPanel) and 0 <= event.cursor_row < len(panel.pids):
            self._last_selected_pid = panel.pids[event.cursor_row]

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        panel = event.data_table.parent
        if isinstance(panel, UnifiedProcessPanel) and 0 <= event.cursor_row < len(panel.pids):
            self._open_details(panel.pids[event.cursor_row])

    async def _collect_once(self) -> None:
        if self.monitoring_paused or self._collecting:
            return
        self._collecting = True
        try:
            snapshot = await asyncio.to_thread(self.service.sample)
            self._apply_snapshot(snapshot)
        except Exception as exc:  # noqa: BLE001 - keep the live dashboard recoverable.
            self.query_one("#status-line", Static).update(
                self.localizer("ui.collector_error", error=exc)
            )
            self.notify(
                str(exc),
                title=self.localizer("ui.collector_error_title"),
                severity="error",
            )
        finally:
            self._collecting = False

    def _apply_snapshot(self, snapshot: MonitorSnapshot) -> None:
        for resource in Resource:
            self.query_one(f"#resource-{resource.value}", ResourceSummary).update_snapshot(
                snapshot,
                self.theme_colors,
                self.localizer,
                self.settings.temperature_unit,
            )
        self.query_one("#process-panel", UnifiedProcessPanel).update_processes(
            self.service.all_processes(self.filter_text),
            top_limit=self.top_limit,
            include_inactive_io=self.settings.include_inactive_io,
        )
        parts = [
            self.localizer("status.updated", time=snapshot.timestamp.strftime("%H:%M:%S")),
            self.localizer("status.top", count=self.top_limit),
        ]
        if self.filter_text:
            parts.append(self.localizer("status.filter", value=self.filter_text))
        if snapshot.errors:
            parts.append(self.localizer("status.limited", count=len(snapshot.errors)))
        self.query_one("#status-line", Static).update("  ·  ".join(parts))

    def _set_responsive_state(self, width: int) -> None:
        self.screen.set_class(width < 100, "compact")

    def _activate_view(self, view: str) -> None:
        self._active_view = view
        process_panel = self.query_one("#process-panel", UnifiedProcessPanel)
        tools_panel = self.query_one("#tools-panel", ToolsPanel)
        process_panel.set_class(view == "top", "active-view")
        tools_panel.set_class(view == "tools", "active-view")
        if self.screen.has_class("compact"):
            target = (
                process_panel.query_one(DataTable)
                if view == "top"
                else tools_panel.query_one(".tool-button", Button)
            )
            target.focus()

    def _focus_resource(self, resource: Resource) -> None:
        sort_key = {
            Resource.CPU: ProcessSort.CPU,
            Resource.MEMORY: ProcessSort.MEMORY,
            Resource.DISK: ProcessSort.DISK_READ,
            Resource.NETWORK: ProcessSort.NETWORK_DOWN,
        }[resource]
        self._activate_view("top")
        self.query_one("#view-tabs", Tabs).active = "tab-top"
        panel = self.query_one("#process-panel", UnifiedProcessPanel)
        panel.set_sort(sort_key, descending=True)
        panel.query_one(DataTable).focus()

    def _selected_process(self) -> ProcessSample | None:
        focused = self.focused
        if isinstance(focused, DataTable) and isinstance(focused.parent, UnifiedProcessPanel):
            pid = focused.parent.selected_pid
        else:
            pid = self._last_selected_pid
        snapshot = self.service.latest
        return snapshot.process_by_pid(pid) if snapshot is not None and pid is not None else None

    def _require_process(self) -> ProcessSample | None:
        process = self._selected_process()
        if process is None:
            self.notify(self.localizer("ui.select_process"), severity="warning")
        return process

    def _open_details(self, pid: int) -> None:
        self._last_selected_pid = pid
        self.push_screen(
            ProcessDetailsScreen(
                self.service,
                pid,
                self.localizer,
                self.theme_colors,
            )
        )

    def _show_result(self, result: ActionResult) -> None:
        self.notify(
            result.message,
            title=self.localizer("ui.process_action" if result.ok else "ui.action_failed"),
            severity="information" if result.ok else "error",
        )

    def on_button_pressed(self, event: Button.Pressed) -> None:
        mode_by_button = {
            "tool-junk": "junk",
            "tool-uninstall": "uninstall",
            "tool-large-files": "large_files",
            "tool-duplicates": "duplicates",
        }
        if event.button.id in mode_by_button:
            self.push_screen(
                MaintenanceScreen(
                    mode_by_button[event.button.id],
                    self.maintenance,
                    self.settings,
                    self.localizer,
                )
            )
            event.stop()
        elif event.button.id == "tool-memory":
            self.push_screen(MemoryReliefScreen(self.service, self.maintenance, self.localizer))
            event.stop()

    def action_settings(self) -> None:
        interfaces = [
            name
            for name, stats in sorted(psutil.net_if_stats().items())
            if stats.isup and name != "lo0" and not name.startswith(("awdl", "llw"))
        ]

        def saved(settings: Settings | None) -> None:
            if settings is None:
                return
            try:
                self.settings_store.save(settings)
            except OSError as exc:
                self._restore_theme_preview()
                self.notify(
                    str(exc),
                    title=self.localizer("ui.settings_save_failed"),
                    severity="error",
                )
                return
            self._apply_settings(settings)
            self.notify(self.localizer("settings.saved"))

        self.push_screen(
            SettingsScreen(
                self.settings,
                self.theme_repository,
                self.localizer,
                interfaces,
                self._preview_theme_id,
                self._preview_theme_colors,
                self._restore_theme_preview,
            ),
            saved,
        )

    def _apply_settings(self, settings: Settings) -> None:
        refresh_changed = settings.refresh_interval != self.settings.refresh_interval
        self.settings = settings
        self.localizer.set_language(settings.language)
        self._localize_bindings()
        self.sub_title = self.localizer("app.subtitle")
        self.top_limit = settings.default_top_rows
        self.service.configure(
            refresh_interval=settings.refresh_interval,
            smoothing_seconds=settings.smoothing_seconds,
            network_interface=settings.network_interface,
            show_self=settings.show_self,
            include_inactive_io=settings.include_inactive_io,
        )
        self.maintenance.set_scan_roots(resolve_scan_roots(settings))
        if refresh_changed and self._refresh_timer is not None:
            self._refresh_timer.stop()
            self._refresh_timer = self.set_interval(settings.refresh_interval, self._collect_once)
        self._preview_theme_id(settings.theme)
        self.current_theme_id = settings.theme
        tabs = self.query_one("#view-tabs", Tabs)
        tabs.get_tab("tab-top").label = self.localizer("view.top")
        tabs.get_tab("tab-tools").label = self.localizer("view.tools")
        process_panel = self.query_one("#process-panel", UnifiedProcessPanel)
        process_panel.set_localizer(self.localizer)
        process_panel.set_sort(
            ProcessSort(settings.default_sort_key),
            descending=settings.default_sort_descending,
        )
        self.query_one("#tools-panel", ToolsPanel).set_localizer(self.localizer)
        snapshot = self.service.latest
        if snapshot is not None:
            self._apply_snapshot(snapshot)

    def _localize_bindings(self, *, refresh: bool = True) -> None:
        localized_actions = {
            "quit",
            "search",
            "filter",
            "terminate",
            "kill",
            "toggle_process",
            "change_priority",
            "settings",
            "top_limit",
            "toggle_monitoring",
            "help",
        }
        for bindings in self._bindings.key_to_bindings.values():
            for index, binding in enumerate(bindings):
                if binding.action in localized_actions:
                    bindings[index] = replace(
                        binding,
                        description=self.localizer(f"binding.{binding.action}"),
                    )
        if refresh:
            self.refresh_bindings()

    def _preview_theme_id(self, theme_id: str) -> None:
        if not self.theme_repository.exists(theme_id):
            theme_id = "graphite-dark"
        theme = self.theme_repository.textual_theme(theme_id)
        self.register_theme(theme)
        self.theme = theme.name
        self.theme_colors = self.theme_repository.resolved_colors(theme_id)
        snapshot = self.service.latest
        if snapshot is not None:
            self._apply_snapshot(snapshot)

    def _preview_theme_colors(self, colors: dict[str, str], mode: str) -> None:
        theme = textual_theme_from_colors("macscope-preview", mode, colors)
        self.register_theme(theme)
        self.theme = theme.name
        self.theme_colors = dict(colors)
        snapshot = self.service.latest
        if snapshot is not None:
            self._apply_snapshot(snapshot)

    def _restore_theme_preview(self) -> None:
        self._preview_theme_id(self.settings.theme)

    def action_search(self) -> None:
        def selected(pid: int | None) -> None:
            if pid is not None:
                self._open_details(pid)

        self.push_screen(SearchScreen(self.service, self.localizer), selected)

    def action_filter(self) -> None:
        def applied(value: str | None) -> None:
            if value is None:
                return
            self.filter_text = value
            snapshot = self.service.latest
            if snapshot is not None:
                self._apply_snapshot(snapshot)

        self.push_screen(
            PromptScreen(
                self.localizer("filter.title"),
                self.localizer("filter.prompt"),
                self.filter_text,
                self.localizer,
            ),
            applied,
        )

    def action_terminate(self) -> None:
        process = self._require_process()
        if process is None:
            return
        self.push_screen(
            ConfirmScreen(
                self.localizer("process.terminate_title"),
                self.localizer("process.terminate_prompt", name=process.name, pid=process.pid),
                self.localizer,
            ),
            lambda confirmed: (
                self._show_result(self.controller.terminate(process)) if confirmed else None
            ),
        )

    def action_kill(self) -> None:
        process = self._require_process()
        if process is None:
            return
        self.push_screen(
            ConfirmScreen(
                self.localizer("process.kill_title"),
                self.localizer("process.kill_prompt", name=process.name, pid=process.pid),
                self.localizer,
            ),
            lambda confirmed: (
                self._show_result(self.controller.terminate(process, force=True))
                if confirmed
                else None
            ),
        )

    def action_toggle_process(self) -> None:
        process = self._require_process()
        if process is None:
            return
        resume = process.status == "stopped"
        action = "resume" if resume else "pause"
        self.push_screen(
            ConfirmScreen(
                self.localizer(f"process.{action}_title"),
                self.localizer(f"process.{action}_prompt", name=process.name, pid=process.pid),
                self.localizer,
            ),
            lambda confirmed: (
                self._show_result(self.controller.toggle_pause(process)) if confirmed else None
            ),
        )

    def action_change_priority(self) -> None:
        process = self._require_process()
        if process is None:
            return
        details = self.service.details(process.pid)
        current = str(details.nice) if details is not None and details.nice is not None else "0"

        def entered(value: str | None) -> None:
            if value is None:
                return
            try:
                priority = int(value)
            except ValueError:
                self.notify(self.localizer("priority.integer"), severity="error")
                return
            if not -20 <= priority <= 20:
                self.notify(self.localizer("priority.range"), severity="error")
                return
            self.push_screen(
                ConfirmScreen(
                    self.localizer("priority.title"),
                    self.localizer(
                        "priority.confirm",
                        name=process.name,
                        pid=process.pid,
                        value=priority,
                    ),
                    self.localizer,
                ),
                lambda confirmed: (
                    self._show_result(self.controller.set_priority(process, priority))
                    if confirmed
                    else None
                ),
            )

        self.push_screen(
            PromptScreen(
                self.localizer("priority.title"),
                self.localizer("priority.prompt"),
                current,
                self.localizer,
            ),
            entered,
        )

    def action_top_limit(self) -> None:
        def entered(value: str | None) -> None:
            if value is None:
                return
            try:
                limit = int(value)
            except ValueError:
                self.notify(self.localizer("rows.integer"), severity="error")
                return
            if not 1 <= limit <= 20:
                self.notify(self.localizer("rows.range"), severity="error")
                return
            self._set_top_limit(limit)

        self.push_screen(
            PromptScreen(
                self.localizer("rows.title"),
                self.localizer("rows.prompt"),
                str(self.top_limit),
                self.localizer,
            ),
            entered,
        )

    def action_increase_top(self) -> None:
        self._set_top_limit(min(20, self.top_limit + 1))

    def action_decrease_top(self) -> None:
        self._set_top_limit(max(1, self.top_limit - 1))

    def _set_top_limit(self, limit: int) -> None:
        if limit == self.top_limit:
            return
        self.top_limit = limit
        snapshot = self.service.latest
        if snapshot is not None:
            self._apply_snapshot(snapshot)
        self.notify(self.localizer("rows.changed", count=limit))

    def action_toggle_monitoring(self) -> None:
        self.monitoring_paused = not self.monitoring_paused
        if self.monitoring_paused:
            self.query_one("#status-line", Static).update(self.localizer("status.paused"))
            self.notify(self.localizer("monitor.paused"))
        else:
            self.notify(self.localizer("monitor.resumed"))
            self.run_worker(self._collect_once(), exclusive=True)

    def action_help(self) -> None:
        self.push_screen(HelpScreen(self.localizer))

    def action_focus_cpu(self) -> None:
        self._focus_resource(Resource.CPU)

    def action_focus_memory(self) -> None:
        self._focus_resource(Resource.MEMORY)

    def action_focus_disk(self) -> None:
        self._focus_resource(Resource.DISK)

    def action_focus_network(self) -> None:
        self._focus_resource(Resource.NETWORK)


def main() -> None:
    MacScopeApp().run()
