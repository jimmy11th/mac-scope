from __future__ import annotations

import asyncio
import threading
import time
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from typing import ClassVar

from rich.text import Text
from textual import events
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.coordinate import Coordinate
from textual.screen import ModalScreen
from textual.timer import Timer
from textual.widgets import Button, DataTable, Label, ProgressBar, Static

from macscope.actions import ProcessController
from macscope.formatting import bytes_value
from macscope.i18n import Localizer
from macscope.maintenance import (
    CleanupFailure,
    CleanupFailureCode,
    CleanupResult,
    MaintenanceItem,
    MaintenanceKind,
    MaintenanceService,
    ScanResult,
)
from macscope.screens import ConfirmScreen
from macscope.service import MonitorService
from macscope.settings import Settings

ACTIVITY_FRAMES = (
    "▰▱▱▱▱▱",
    "▱▰▱▱▱▱",
    "▱▱▰▱▱▱",
    "▱▱▱▰▱▱",
    "▱▱▱▱▰▱",
    "▱▱▱▱▱▰",
    "▱▱▱▱▰▱",
    "▱▱▱▰▱▱",
    "▱▱▰▱▱▱",
    "▱▰▱▱▱▱",
)
MIN_ACTIVITY_SECONDS = 0.36


def cleanup_state(localizer: Localizer, state: str) -> str:
    return localizer(f"maintenance.cleanup_state.{state}")


def activity_line(screen: ModalScreen, frame: str, message: str) -> Text:
    colors = getattr(screen.app, "theme_colors", {})
    line = Text(frame, style=f"bold {colors.get('accent', 'cyan')}")
    line.append(f"  {message}", style=f"bold {colors.get('text', 'white')}")
    return line


def update_state_cell(
    table: DataTable,
    items: list[MaintenanceItem] | tuple[MaintenanceItem, ...],
    item: MaintenanceItem,
    state: str,
    color: str,
) -> None:
    row = next((index for index, candidate in enumerate(items) if candidate.id == item.id), None)
    if row is not None:
        table.update_cell_at(Coordinate(row, 3), Text(state, style=f"bold {color}"))


class MaintenanceScreen(ModalScreen[None]):
    BINDINGS: ClassVar[list[Binding]] = [
        Binding("escape", "close", "Close", show=False),
        Binding("space", "toggle", "Select", show=False),
        Binding("a", "select_all", "Select all", show=False),
        Binding("r", "scan", "Rescan", show=False),
        Binding("d", "clean", "Clean", show=False),
    ]

    def __init__(
        self,
        mode: str,
        maintenance: MaintenanceService,
        settings: Settings,
        localizer: Localizer,
    ) -> None:
        super().__init__()
        self.mode = mode
        self.maintenance = maintenance
        self.settings = settings
        self.localizer = localizer
        self.items: list[MaintenanceItem] = []
        self.visible_items: list[MaintenanceItem] = []
        self.selected: set[str] = set()
        self.failures: dict[str, CleanupFailure] = {}
        self.completed: set[str] = set()
        self._cancel = threading.Event()
        self._scanning = False
        self._cleaning = False
        self.progress_states: dict[str, str] = {}
        self._activity_timer: Timer | None = None
        self._activity_frame = 0
        self._activity_message = ""
        self._last_scan_progress = 0.0

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog maintenance-dialog"):
            yield Label(self.localizer(f"maintenance.{self.mode}.title"), classes="dialog-title")
            with Horizontal(classes="maintenance-summary"):
                yield Static(self.localizer("maintenance.ready"), id="maintenance-status")
                yield Static("", id="maintenance-total")
            yield ProgressBar(
                total=1,
                show_eta=False,
                id="maintenance-progress",
            )
            yield Static("", id="maintenance-current")
            yield DataTable(
                cursor_type="row",
                zebra_stripes=True,
                id="maintenance-results",
            )
            with Horizontal(classes="dialog-actions maintenance-actions"):
                yield Button(self.localizer("maintenance.rescan"), id="maintenance-rescan")
                yield Button(
                    self._select_all_label(),
                    id="maintenance-select-all",
                    disabled=True,
                )
                yield Button(
                    self.localizer("maintenance.clean"),
                    variant="primary",
                    id="maintenance-clean",
                    disabled=True,
                )
                yield Button(self.localizer("common.close"), id="maintenance-close")

    def on_mount(self) -> None:
        self.set_class(self.size.width < 100, "compact")
        table = self.query_one("#maintenance-results", DataTable)
        table.add_columns(
            self.localizer("maintenance.selected"),
            self.localizer("maintenance.category"),
            self.localizer("maintenance.item"),
            self.localizer("maintenance.state"),
            self.localizer("maintenance.size"),
            self.localizer("maintenance.modified"),
            self.localizer("maintenance.path"),
        )
        if self.mode == "uninstall":
            self.query_one("#maintenance-select-all", Button).display = False
            self.query_one("#maintenance-clean", Button).display = False
        self.action_scan()

    def on_resize(self, event: events.Resize) -> None:
        self.set_class(event.size.width < 100, "compact")

    def on_unmount(self) -> None:
        self._cancel.set()
        self._stop_activity()

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        if event.data_table.id == "maintenance-results":
            if self.mode == "uninstall":
                self._open_uninstall_dialog(event.cursor_row)
            else:
                self._toggle_row(event.cursor_row)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        button_id = event.button.id
        if button_id == "maintenance-close":
            self.action_close()
        elif button_id == "maintenance-rescan":
            self.action_scan()
        elif button_id == "maintenance-select-all":
            self.action_select_all()
        elif button_id == "maintenance-clean":
            self.action_clean()

    def action_close(self) -> None:
        if self._cleaning:
            return
        self._cancel.set()
        self.dismiss(None)

    def action_toggle(self) -> None:
        table = self.query_one("#maintenance-results", DataTable)
        if self.mode == "uninstall":
            self._open_uninstall_dialog(table.cursor_row)
        else:
            self._toggle_row(table.cursor_row)

    def action_select_all(self) -> None:
        if self.mode == "uninstall":
            return
        selectable = self._selectable_ids()
        if not selectable:
            return
        self.selected = set() if selectable.issubset(self.selected) else selectable
        self._render_items()

    def action_scan(self) -> None:
        if self._scanning or self._cleaning:
            return
        self._cancel.set()
        self._cancel = threading.Event()
        self.run_worker(self._scan(), group="maintenance-scan", exclusive=True)

    def action_clean(self) -> None:
        if self._scanning or self._cleaning:
            return
        if self.mode == "uninstall":
            self._open_uninstall_dialog(
                self.query_one("#maintenance-results", DataTable).cursor_row
            )
            return
        selected = [item for item in self.items if item.id in self.selected]
        if not selected:
            self.notify(self.localizer("maintenance.select_first"), severity="warning")
            return
        if self.mode == "duplicates" and not self._duplicates_leave_one(selected):
            self.notify(self.localizer("maintenance.keep_duplicate"), severity="warning")
            return
        if self.mode == "uninstall" and not self._uninstall_has_parents(selected):
            self.notify(self.localizer("maintenance.select_app_first"), severity="warning")
            return
        size = sum(item.size for item in selected)

        def confirmed(value: bool) -> None:
            if value:
                self.run_worker(self._clean(selected), group="maintenance-clean", exclusive=True)

        self.app.push_screen(
            ConfirmScreen(
                self.localizer("maintenance.confirm_title"),
                self._confirmation_message(selected, size),
                self.localizer,
            ),
            confirmed,
        )

    async def _scan(self) -> None:
        self._scanning = True
        self._set_buttons_disabled(True)
        self.query_one("#maintenance-status", Static).update(self.localizer("maintenance.scanning"))
        self.query_one("#maintenance-results", DataTable).clear(columns=False)
        try:
            result = await asyncio.to_thread(self._run_scanner)
            if self._cancel.is_set():
                return
            self.items = list(result.items)
            self.selected.clear()
            self.failures.clear()
            self.completed.clear()
            self.progress_states.clear()
            self._render_items()
            if self.mode == "uninstall":
                applications = sum(
                    item.kind is MaintenanceKind.APPLICATION for item in result.items
                )
                related = sum(item.kind is MaintenanceKind.RESIDUE for item in result.items)
                status_key = (
                    "maintenance.uninstall.scan_with_errors"
                    if result.errors
                    else "maintenance.uninstall.scan_done"
                )
                status = self.localizer(
                    status_key,
                    apps=applications,
                    related=related,
                    errors=len(result.errors),
                )
            else:
                status_key = (
                    "maintenance.scan_with_errors" if result.errors else "maintenance.scan_done"
                )
                status = self.localizer(
                    status_key,
                    count=len(result.items),
                    files=result.scanned_files,
                    errors=len(result.errors),
                )
            self.query_one("#maintenance-status", Static).update(status)
        except Exception as exc:  # noqa: BLE001 - scanning must leave the screen usable.
            self.query_one("#maintenance-status", Static).update(str(exc))
            self.notify(str(exc), severity="error")
        finally:
            self._scanning = False
            if self.is_mounted:
                self._set_buttons_disabled(False)

    def _run_scanner(self) -> ScanResult:
        progress = self._progress_from_thread
        if self.mode == "junk":
            return self.maintenance.scan_junk(self._cancel, progress)
        if self.mode == "uninstall":
            return self.maintenance.scan_applications(self._cancel, progress)
        if self.mode == "large_files":
            return self.maintenance.scan_large_files(
                self.settings.large_file_threshold_mb,
                self._cancel,
                progress,
            )
        if self.mode == "duplicates":
            return self.maintenance.scan_duplicates(
                minimum_size=self.settings.duplicate_minimum_size_mb * 1024 * 1024,
                cancel=self._cancel,
                progress=progress,
            )
        raise ValueError(f"unsupported maintenance mode: {self.mode}")

    async def _clean(self, items: list[MaintenanceItem]) -> None:
        self._cleaning = True
        started_at = time.monotonic()
        self._set_buttons_disabled(True)
        self.progress_states.update({item.id: "queued" for item in items})
        self._show_cleanup_progress(len(items))
        self._start_activity(self.localizer("maintenance.cleaning"))
        self._render_items()
        try:
            result = await asyncio.to_thread(
                self.maintenance.cleanup,
                items,
                cache_mode=self.settings.cache_cleanup_mode,
                progress=self._cleanup_progress_from_thread,
            )
            remaining = MIN_ACTIVITY_SECONDS - (time.monotonic() - started_at)
            if remaining > 0:
                await asyncio.sleep(remaining)
            if self.is_mounted:
                self._apply_cleanup_result(result)
        except Exception as exc:  # noqa: BLE001 - keep cleanup results visible.
            self.notify(str(exc), severity="error")
        finally:
            self._stop_activity()
            self._cleaning = False
            if self.is_mounted:
                self._set_buttons_disabled(False)

    def _apply_cleanup_result(self, result: CleanupResult) -> None:
        successful = result.deleted + result.trashed
        processed = {item.id for item in successful}
        current_failures = {failure.item.id: failure for failure in result.errors}
        self.progress_states.update({item.id: "deleted" for item in result.deleted})
        self.progress_states.update({item.id: "trashed" for item in result.trashed})
        self.progress_states.update({item_id: "failed" for item_id in current_failures})
        for item_id in processed:
            self.failures.pop(item_id, None)
        self.failures.update(current_failures)
        self.completed.update(processed)
        self.completed.difference_update(current_failures)
        self.selected.difference_update(processed)
        self.selected.update(current_failures)
        self._render_items()
        if self.mode == "uninstall":
            status = self.localizer(
                "maintenance.uninstall.result",
                apps=sum(item.kind is MaintenanceKind.APPLICATION for item in successful),
                related=sum(item.kind is MaintenanceKind.RESIDUE for item in successful),
                kept=len(self.failures),
            )
        else:
            status = self.localizer(
                "maintenance.cleaned",
                deleted=len(result.deleted),
                reclaimed=bytes_value(result.reclaimed_bytes),
                trashed=len(result.trashed),
                trash_size=bytes_value(result.trashed_bytes),
                errors=len(result.errors),
            )
        self.query_one("#maintenance-status", Static).update(status)
        current = self.query_one("#maintenance-current", Static)
        current.update("")
        current.remove_class("active")

    def _toggle_row(self, row: int) -> None:
        if self.mode == "uninstall":
            self._open_uninstall_dialog(row)
            return
        if not 0 <= row < len(self.visible_items):
            return
        item = self.visible_items[row]
        if item.id in self.completed:
            self.notify(self.localizer("maintenance.already_removed"))
            return
        if item.blocked_reason:
            self.notify(self.localizer(item.blocked_reason), severity="warning")
            return
        if item.id in self.selected:
            self.selected.remove(item.id)
            if item.kind is MaintenanceKind.APPLICATION:
                self.selected.difference_update(
                    child.id for child in self.items if child.parent_id == item.id
                )
        else:
            if (
                item.kind is MaintenanceKind.RESIDUE
                and item.parent_id not in self.selected
                and item.parent_id not in self.completed
            ):
                self.notify(self.localizer("maintenance.select_app_first"), severity="warning")
                return
            self.selected.add(item.id)
        self._render_items(cursor_row=row)

    def _render_items(self, cursor_row: int | None = None) -> None:
        table = self.query_one("#maintenance-results", DataTable)
        if cursor_row is None:
            cursor_row = table.cursor_row
        cursor_id = (
            self.visible_items[cursor_row].id if 0 <= cursor_row < len(self.visible_items) else ""
        )
        self.visible_items = self._visible_items()
        table.clear(columns=False)
        colors = getattr(self.app, "theme_colors", {})
        accent = colors.get("accent", "cyan")
        muted = colors.get("muted", "grey50")
        normal = colors.get("normal", "green")
        danger = colors.get("danger", "red")
        for item in self.visible_items:
            is_selected = item.id in self.selected
            is_completed = item.id in self.completed
            failure = self.failures.get(item.id)
            if failure is not None:
                style = f"bold {danger}"
            elif is_completed:
                style = f"bold {normal}"
            else:
                style = f"bold {accent}" if is_selected else ""
            child_style = (
                muted
                if item.parent_id and not is_selected and failure is None and not is_completed
                else style
            )
            state = self.localizer(item.blocked_reason) if item.blocked_reason else ""
            if failure is not None:
                state = self.localizer(f"maintenance.failure.{failure.code.value}")
                if failure.code is CleanupFailureCode.TRASH_FAILED and failure.detail:
                    state = f"{state}: {failure.detail}"
            elif is_completed:
                state = cleanup_state(
                    self.localizer,
                    self.progress_states.get(item.id, "trashed"),
                )
            elif item.id in self.progress_states:
                state = cleanup_state(self.localizer, self.progress_states[item.id])
            if not state and item.category_key in {
                "maintenance.category.app_support",
                "maintenance.category.container",
            }:
                state = self.localizer("maintenance.user_data")
            name = f"  ↳ {item.name}" if item.parent_id else item.name
            table.add_row(
                Text(
                    (
                        "[✓]"
                        if is_selected or is_completed
                        else " › "
                        if self.mode == "uninstall"
                        else "[ ]"
                    ),
                    style=style or muted,
                ),
                Text(self.localizer(item.category_key), style=child_style),
                Text(name, style=child_style),
                Text(state, style=child_style),
                Text(bytes_value(item.size), style=style),
                Text(
                    datetime.fromtimestamp(item.modified).astimezone().strftime("%Y-%m-%d"),
                    style=style,
                ),
                Text(str(item.path), style=child_style),
                key=item.id,
            )
        if self.visible_items:
            target_row = (
                next(
                    (
                        index
                        for index, item in enumerate(self.visible_items)
                        if item.id == cursor_id
                    ),
                    min(max(0, cursor_row), len(self.visible_items) - 1),
                )
                if cursor_id
                else min(max(0, cursor_row), len(self.visible_items) - 1)
            )
            table.move_cursor(row=target_row, animate=False)
        selected_size = sum(item.size for item in self.items if item.id in self.selected)
        if self.mode == "uninstall":
            apps = [
                item
                for item in self.items
                if item.kind is MaintenanceKind.APPLICATION and item.id not in self.completed
            ]
            selected_apps = sum(item.id in self.selected for item in apps)
            selected_related = sum(
                item.id in self.selected
                for item in self.items
                if item.kind is MaintenanceKind.RESIDUE
            )
            total = self.localizer(
                "maintenance.uninstall.total",
                count=len(apps),
                size=bytes_value(sum(item.size for item in apps)),
                selected=selected_apps,
                related=selected_related,
                selected_size=bytes_value(selected_size),
            )
        else:
            total = self.localizer(
                "maintenance.total",
                count=len(self.items),
                size=bytes_value(sum(item.size for item in self.items)),
                selected=len(self.selected),
                selected_size=bytes_value(selected_size),
            )
        self.query_one("#maintenance-total", Static).update(total)
        self._update_action_state(selected_size)

    def _visible_items(self) -> list[MaintenanceItem]:
        if self.mode != "uninstall":
            return list(self.items)
        return [item for item in self.items if item.kind is MaintenanceKind.APPLICATION]

    def _selectable_ids(self) -> set[str]:
        if self.mode == "uninstall":
            return set()
        if self.mode == "duplicates":
            grouped: dict[str, list[MaintenanceItem]] = defaultdict(list)
            for item in self.items:
                grouped[item.group].append(item)
            return {
                item.id
                for group_items in grouped.values()
                for item in group_items[1:]
                if item.id not in self.completed and not item.blocked_reason
            }
        return {
            item.id
            for item in self.items
            if item.id not in self.completed and not item.blocked_reason
        }

    def _select_all_label(self) -> str:
        key = (
            "maintenance.select_all_apps" if self.mode == "uninstall" else "maintenance.select_all"
        )
        return self.localizer(key)

    def _update_action_state(self, selected_size: int | None = None) -> None:
        if not self.is_mounted:
            return
        if self.mode == "uninstall":
            self.query_one("#maintenance-clean", Button).disabled = True
            self.query_one("#maintenance-select-all", Button).disabled = True
            return
        selected_items = [item for item in self.items if item.id in self.selected]
        selected_size = (
            selected_size
            if selected_size is not None
            else sum(item.size for item in selected_items)
        )
        clean = self.query_one("#maintenance-clean", Button)
        if selected_items:
            retry_count = sum(item.id in self.failures for item in selected_items)
            retry_only = retry_count == len(selected_items)
            if retry_only:
                clean.label = self.localizer("maintenance.retry", count=retry_count)
            elif self.mode == "uninstall":
                apps = sum(item.kind is MaintenanceKind.APPLICATION for item in selected_items)
                related = sum(item.kind is MaintenanceKind.RESIDUE for item in selected_items)
                clean.label = self.localizer(
                    "maintenance.uninstall.action",
                    apps=apps,
                    related=related,
                    size=bytes_value(selected_size),
                )
            else:
                clean.label = self.localizer(
                    "maintenance.clean_count",
                    count=len(selected_items),
                    size=bytes_value(selected_size),
                )
        else:
            clean.label = self.localizer("maintenance.clean")
        clean.disabled = self._scanning or self._cleaning or not selected_items
        selectable = self._selectable_ids()
        select_all = self.query_one("#maintenance-select-all", Button)
        select_all.label = self.localizer(
            "maintenance.deselect_all"
            if selectable and selectable.issubset(self.selected)
            else (
                "maintenance.select_all_apps"
                if self.mode == "uninstall"
                else "maintenance.select_all"
            )
        )
        select_all.disabled = self._scanning or self._cleaning or not selectable

    def _confirmation_message(self, selected: list[MaintenanceItem], size: int) -> str:
        retry_count = sum(item.id in self.failures for item in selected)
        if retry_count == len(selected):
            return self.localizer("maintenance.retry_confirm", count=retry_count)
        if self.mode == "uninstall":
            apps = sum(item.kind is MaintenanceKind.APPLICATION for item in selected)
            related = sum(item.kind is MaintenanceKind.RESIDUE for item in selected)
            return self.localizer(
                "maintenance.uninstall.confirm",
                apps=apps,
                related=related,
                size=bytes_value(size),
            )
        if self.mode == "junk":
            return self.localizer(
                "maintenance.junk.confirm",
                count=len(selected),
                size=bytes_value(size),
            )
        return self.localizer(
            "maintenance.confirm",
            count=len(selected),
            size=bytes_value(size),
        )

    def _uninstall_has_parents(self, selected: list[MaintenanceItem]) -> bool:
        selected_ids = {item.id for item in selected}
        return all(
            item.kind is not MaintenanceKind.RESIDUE
            or item.parent_id in selected_ids
            or item.parent_id in self.completed
            for item in selected
        )

    def _duplicates_leave_one(self, selected: list[MaintenanceItem]) -> bool:
        selected_ids = {item.id for item in selected}
        groups: dict[str, list[MaintenanceItem]] = defaultdict(list)
        for item in self.items:
            groups[item.group].append(item)
        return all(
            any(item.id not in selected_ids for item in group_items)
            for group_items in groups.values()
        )

    def _progress_from_thread(self, count: int, path: str) -> None:
        now = time.monotonic()
        if now - self._last_scan_progress < 0.08:
            return
        self._last_scan_progress = now
        try:
            self.app.call_from_thread(self._update_progress, count, path)
        except RuntimeError:
            pass

    def _update_progress(self, count: int, path: str) -> None:
        if self.is_mounted:
            self.query_one("#maintenance-status", Static).update(
                self.localizer("maintenance.progress", count=count, path=path[-48:])
            )

    def _set_buttons_disabled(self, disabled: bool) -> None:
        self.query_one("#maintenance-rescan", Button).disabled = disabled
        self.query_one("#maintenance-close", Button).disabled = self._cleaning
        self._update_action_state()

    def _open_uninstall_dialog(self, row: int) -> None:
        if self._scanning or self._cleaning or not 0 <= row < len(self.visible_items):
            return
        application = self.visible_items[row]
        if application.id in self.completed:
            self.notify(self.localizer("maintenance.already_removed"))
            return
        if application.blocked_reason:
            self.notify(self.localizer(application.blocked_reason), severity="warning")
            return
        related = tuple(item for item in self.items if item.parent_id == application.id)

        def completed(result: CleanupResult | None) -> None:
            if result is not None:
                self._apply_cleanup_result(result)

        self.app.push_screen(
            UninstallDetailsScreen(
                application,
                related,
                self.maintenance,
                self.settings,
                self.localizer,
            ),
            completed,
        )

    def _show_cleanup_progress(self, total: int) -> None:
        progress = self.query_one("#maintenance-progress", ProgressBar)
        progress.add_class("active")
        progress.update(total=max(1, total), progress=0)
        self.query_one("#maintenance-current", Static).add_class("active")

    def _cleanup_progress_from_thread(
        self,
        completed: int,
        total: int,
        item: MaintenanceItem,
        state: str,
    ) -> None:
        try:
            self.app.call_from_thread(
                self._update_cleanup_progress,
                completed,
                total,
                item,
                state,
            )
        except RuntimeError:
            pass

    def _update_cleanup_progress(
        self,
        completed: int,
        total: int,
        item: MaintenanceItem,
        state: str,
    ) -> None:
        if not self.is_mounted:
            return
        self.progress_states[item.id] = state
        self.query_one("#maintenance-progress", ProgressBar).update(
            total=max(1, total),
            progress=completed,
        )
        self._activity_message = self.localizer(
            "maintenance.cleaning_item",
            current=min(completed + (state == "processing"), total),
            total=total,
            item=item.name,
            path=str(item.path),
        )
        colors = getattr(self.app, "theme_colors", {})
        update_state_cell(
            self.query_one("#maintenance-results", DataTable),
            self.visible_items,
            item,
            cleanup_state(self.localizer, state),
            colors.get("accent", "cyan"),
        )

    def _start_activity(self, message: str) -> None:
        self._activity_message = message
        self._activity_frame = 0
        self._stop_activity()
        self._activity_timer = self.set_interval(0.16, self._animate_activity)
        self._animate_activity()

    def _animate_activity(self) -> None:
        if not self.is_mounted:
            return
        frame = ACTIVITY_FRAMES[self._activity_frame % len(ACTIVITY_FRAMES)]
        self._activity_frame += 1
        self.query_one("#maintenance-current", Static).update(
            activity_line(self, frame, self._activity_message)
        )

    def _stop_activity(self) -> None:
        if self._activity_timer is not None:
            self._activity_timer.stop()
            self._activity_timer = None


class UninstallDetailsScreen(ModalScreen[CleanupResult | None]):
    BINDINGS: ClassVar[list[Binding]] = [
        Binding("escape", "close", "Close", show=False),
        Binding("space", "toggle", "Select", show=False),
        Binding("a", "select_related", "Select related", show=False),
    ]

    def __init__(
        self,
        application: MaintenanceItem,
        related: tuple[MaintenanceItem, ...],
        maintenance: MaintenanceService,
        settings: Settings,
        localizer: Localizer,
    ) -> None:
        super().__init__()
        self.application = application
        self.related = related
        self.copy_items: tuple[MaintenanceItem, ...] = ()
        self.items: list[MaintenanceItem] = [application, *related]
        self.maintenance = maintenance
        self.settings = settings
        self.localizer = localizer
        safe_defaults = {
            "maintenance.category.app_cache",
            "maintenance.category.preference",
            "maintenance.category.saved_state",
        }
        self.selected = {application.id} | {
            item.id for item in related if item.category_key in safe_defaults
        }
        self.completed: set[str] = set()
        self.failures: dict[str, CleanupFailure] = {}
        self.progress_states: dict[str, str] = {}
        self.other_copies: tuple[Path, ...] = ()
        self._deleted: dict[str, MaintenanceItem] = {}
        self._trashed: dict[str, MaintenanceItem] = {}
        self._attempted = False
        self._cleaning = False
        self._copies_loading = True
        self._activity_timer: Timer | None = None
        self._activity_frame = 0
        self._activity_message = ""

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog uninstall-dialog"):
            yield Label(
                self.localizer("maintenance.uninstall.review_title"),
                classes="dialog-title",
            )
            yield Static(
                self.localizer(
                    "maintenance.uninstall.app_summary",
                    name=self.application.name,
                    bundle=self.application.group or self.localizer("common.unavailable"),
                    size=bytes_value(self.application.size),
                ),
                id="uninstall-app-summary",
            )
            yield Static("", id="uninstall-copy-warning")
            yield ProgressBar(total=1, show_eta=False, id="uninstall-progress")
            yield Static("", id="uninstall-current")
            yield DataTable(cursor_type="row", zebra_stripes=True, id="uninstall-items")
            with Horizontal(classes="dialog-actions maintenance-actions"):
                yield Button(
                    self.localizer("maintenance.uninstall.select_related"),
                    id="uninstall-select-related",
                )
                yield Button(
                    self.localizer("maintenance.uninstall.single_action"),
                    variant="error",
                    id="uninstall-confirm",
                )
                yield Button(self.localizer("common.cancel"), id="uninstall-close")

    def on_mount(self) -> None:
        table = self.query_one("#uninstall-items", DataTable)
        table.add_columns(
            self.localizer("maintenance.selected"),
            self.localizer("maintenance.category"),
            self.localizer("maintenance.item"),
            self.localizer("maintenance.state"),
            self.localizer("maintenance.size"),
            self.localizer("maintenance.path"),
        )
        self._render_items()
        warning = self.query_one("#uninstall-copy-warning", Static)
        warning.update(self.localizer("maintenance.uninstall.checking_copies"))
        warning.add_class("visible")
        self.run_worker(self._load_other_copies(), exclusive=True)

    def on_unmount(self) -> None:
        self._stop_activity()

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        if event.data_table.id == "uninstall-items":
            self._toggle_row(event.cursor_row)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "uninstall-close":
            self.action_close()
        elif event.button.id == "uninstall-select-related":
            self.action_select_related()
        elif event.button.id == "uninstall-confirm":
            self._begin_cleanup()

    def action_close(self) -> None:
        if self._cleaning:
            return
        result = None
        if self._attempted:
            result = CleanupResult(
                tuple(self._deleted.values()),
                tuple(self._trashed.values()),
                tuple(self.failures.values()),
            )
        self.dismiss(result)

    def action_toggle(self) -> None:
        self._toggle_row(self.query_one("#uninstall-items", DataTable).cursor_row)

    def action_select_related(self) -> None:
        if self._cleaning:
            return
        selectable = {
            item.id
            for item in self.related
            if item.id not in self.completed and not item.blocked_reason
        }
        if selectable and selectable.issubset(self.selected):
            self.selected.difference_update(selectable)
        else:
            self.selected.update(selectable)
        if self.application.id not in self.completed:
            self.selected.add(self.application.id)
        self._render_items()

    async def _load_other_copies(self) -> None:
        copy_items = await asyncio.to_thread(
            self.maintenance.application_copy_items,
            self.application.group,
            excluding=self.application.path,
        )
        if not self.is_mounted:
            return
        table = self.query_one("#uninstall-items", DataTable)
        cursor_item_id = (
            self.items[table.cursor_row].id if 0 <= table.cursor_row < len(self.items) else ""
        )
        self.copy_items = copy_items
        self.other_copies = tuple(item.path for item in copy_items)
        self.items = [self.application, *copy_items, *self.related]
        self._copies_loading = False
        warning = self.query_one("#uninstall-copy-warning", Static)
        if copy_items:
            warning.update(
                self.localizer(
                    "maintenance.uninstall.other_copies",
                    count=len(copy_items),
                )
            )
            warning.add_class("visible")
        else:
            warning.update("")
            warning.remove_class("visible")
        cursor_row = next(
            (
                index
                for index, item in enumerate(self.items)
                if item.id == cursor_item_id
            ),
            0,
        )
        self._render_items(cursor_row=cursor_row)

    def _toggle_row(self, row: int) -> None:
        if self._cleaning or not 0 <= row < len(self.items):
            return
        item = self.items[row]
        if item.id == self.application.id or item.id in self.completed:
            return
        if item.blocked_reason:
            self.notify(self.localizer(item.blocked_reason), severity="warning")
            return
        if item.id in self.selected:
            self.selected.remove(item.id)
        else:
            self.selected.add(item.id)
        if self.application.id not in self.completed:
            self.selected.add(self.application.id)
        self._render_items(cursor_row=row)

    def _render_items(self, cursor_row: int | None = None) -> None:
        table = self.query_one("#uninstall-items", DataTable)
        if cursor_row is None:
            cursor_row = table.cursor_row
        table.clear(columns=False)
        colors = getattr(self.app, "theme_colors", {})
        accent = colors.get("accent", "cyan")
        muted = colors.get("muted", "grey50")
        normal = colors.get("normal", "green")
        danger = colors.get("danger", "red")
        warning = colors.get("warning", "yellow")
        for item in self.items:
            selected = item.id in self.selected
            completed = item.id in self.completed
            failure = self.failures.get(item.id)
            style = f"bold {accent}" if selected else muted
            if completed:
                style = f"bold {normal}"
            if failure is not None:
                style = f"bold {danger}"
            elif item.blocked_reason:
                style = f"bold {warning}"
            if failure is not None:
                state = self.localizer(f"maintenance.failure.{failure.code.value}")
            elif item.blocked_reason:
                state = self.localizer(item.blocked_reason)
            elif item.id in self.progress_states:
                state = cleanup_state(self.localizer, self.progress_states[item.id])
            elif item.category_key in {
                "maintenance.category.app_support",
                "maintenance.category.container",
            }:
                state = self.localizer("maintenance.user_data")
            elif item.kind is MaintenanceKind.APPLICATION:
                state = self.localizer(
                    "maintenance.uninstall.required"
                    if item.id == self.application.id
                    else "maintenance.uninstall.copy_optional"
                )
            else:
                state = ""
            table.add_row(
                Text("[✓]" if selected or completed else "[ ]", style=style),
                Text(self.localizer(item.category_key), style=style),
                Text(item.name, style=style),
                Text(state, style=style),
                Text(bytes_value(item.size), style=style),
                Text(str(item.path), style=style),
                key=item.id,
            )
        if self.items:
            table.move_cursor(
                row=min(max(0, cursor_row), len(self.items) - 1),
                animate=False,
            )
        self._update_actions()

    def _update_actions(self) -> None:
        pending = [
            item
            for item in self.items
            if item.id in self.selected and item.id not in self.completed
        ]
        related_count = sum(item.kind is MaintenanceKind.RESIDUE for item in pending)
        app_count = sum(item.kind is MaintenanceKind.APPLICATION for item in pending)
        size = sum(item.size for item in pending)
        action = self.query_one("#uninstall-confirm", Button)
        if self.failures and {item.id for item in pending} == set(self.failures):
            action.label = self.localizer("maintenance.retry", count=len(pending))
        elif self.application.id in self.completed and not app_count:
            action.label = self.localizer(
                "maintenance.clean_count",
                count=len(pending),
                size=bytes_value(size),
            )
        else:
            action.label = self.localizer(
                "maintenance.uninstall.single_action_detail",
                apps=app_count,
                related=related_count,
                size=bytes_value(size),
            )
        action.disabled = self._cleaning or self._copies_loading or not pending
        select_related = self.query_one("#uninstall-select-related", Button)
        selectable = {
            item.id
            for item in self.related
            if item.id not in self.completed and not item.blocked_reason
        }
        select_related.label = self.localizer(
            "maintenance.deselect_all"
            if selectable and selectable.issubset(self.selected)
            else "maintenance.uninstall.select_related"
        )
        select_related.disabled = self._cleaning or not selectable

    def _begin_cleanup(self) -> None:
        if self._cleaning or self._copies_loading:
            return
        pending = [
            item
            for item in self.items
            if item.id in self.selected and item.id not in self.completed
        ]
        if not pending:
            return
        self.run_worker(self._clean(pending), group="uninstall-clean", exclusive=True)

    async def _clean(self, items: list[MaintenanceItem]) -> None:
        self._cleaning = True
        started_at = time.monotonic()
        self._attempted = True
        self.progress_states.update({item.id: "queued" for item in items})
        progress = self.query_one("#uninstall-progress", ProgressBar)
        progress.add_class("active")
        progress.update(total=max(1, len(items)), progress=0)
        self.query_one("#uninstall-current", Static).add_class("active")
        self._start_activity(self.localizer("maintenance.cleaning"))
        self._render_items()
        try:
            result = await asyncio.to_thread(
                self.maintenance.cleanup,
                items,
                cache_mode=self.settings.cache_cleanup_mode,
                progress=self._progress_from_thread,
            )
            remaining = MIN_ACTIVITY_SECONDS - (time.monotonic() - started_at)
            if remaining > 0:
                await asyncio.sleep(remaining)
            if self.is_mounted:
                self._apply_result(result)
        except Exception as exc:  # noqa: BLE001 - keep the uninstall dialog recoverable.
            self.notify(str(exc), severity="error")
        finally:
            self._stop_activity()
            self._cleaning = False
            if self.is_mounted:
                self._render_items()

    def _apply_result(self, result: CleanupResult) -> None:
        self.progress_states.update({item.id: "deleted" for item in result.deleted})
        self.progress_states.update({item.id: "trashed" for item in result.trashed})
        for item in result.deleted:
            self._deleted[item.id] = item
            self._trashed.pop(item.id, None)
            self.failures.pop(item.id, None)
            self.completed.add(item.id)
        for item in result.trashed:
            self._trashed[item.id] = item
            self._deleted.pop(item.id, None)
            self.failures.pop(item.id, None)
            self.completed.add(item.id)
        current_failures = {failure.item.id: failure for failure in result.errors}
        self.progress_states.update({item_id: "failed" for item_id in current_failures})
        self.failures.update(current_failures)
        self.completed.difference_update(current_failures)
        self.selected = set(current_failures)
        if self.application.id not in self.completed and self.application.id not in self.failures:
            self.selected.add(self.application.id)
        status = self.localizer(
            "maintenance.uninstall.result",
            apps=sum(
                item.kind is MaintenanceKind.APPLICATION for item in result.deleted + result.trashed
            ),
            related=sum(
                item.kind is MaintenanceKind.RESIDUE for item in result.deleted + result.trashed
            ),
            kept=len(result.errors),
        )
        remaining_copies = [item for item in self.copy_items if item.id not in self.completed]
        warning = self.query_one("#uninstall-copy-warning", Static)
        if remaining_copies:
            warning.update(
                self.localizer(
                    "maintenance.uninstall.other_copies",
                    count=len(remaining_copies),
                )
            )
            warning.add_class("visible")
        else:
            warning.update("")
            warning.remove_class("visible")
        self.query_one("#uninstall-current", Static).update(status)
        self.query_one("#uninstall-close", Button).label = self.localizer("common.close")
        self._render_items()

    def _progress_from_thread(
        self,
        completed: int,
        total: int,
        item: MaintenanceItem,
        state: str,
    ) -> None:
        try:
            self.app.call_from_thread(
                self._update_progress,
                completed,
                total,
                item,
                state,
            )
        except RuntimeError:
            pass

    def _update_progress(
        self,
        completed: int,
        total: int,
        item: MaintenanceItem,
        state: str,
    ) -> None:
        if not self.is_mounted:
            return
        self.progress_states[item.id] = state
        self.query_one("#uninstall-progress", ProgressBar).update(
            total=max(1, total),
            progress=completed,
        )
        self._activity_message = self.localizer(
            "maintenance.cleaning_item",
            current=min(completed + (state == "processing"), total),
            total=total,
            item=item.name,
            path=str(item.path),
        )
        colors = getattr(self.app, "theme_colors", {})
        update_state_cell(
            self.query_one("#uninstall-items", DataTable),
            self.items,
            item,
            cleanup_state(self.localizer, state),
            colors.get("accent", "cyan"),
        )

    def _start_activity(self, message: str) -> None:
        self._activity_message = message
        self._activity_frame = 0
        self._stop_activity()
        self._activity_timer = self.set_interval(0.16, self._animate_activity)
        self._animate_activity()

    def _animate_activity(self) -> None:
        if not self.is_mounted:
            return
        frame = ACTIVITY_FRAMES[self._activity_frame % len(ACTIVITY_FRAMES)]
        self._activity_frame += 1
        self.query_one("#uninstall-current", Static).update(
            activity_line(self, frame, self._activity_message)
        )

    def _stop_activity(self) -> None:
        if self._activity_timer is not None:
            self._activity_timer.stop()
            self._activity_timer = None


class MemoryReliefScreen(ModalScreen[None]):
    BINDINGS: ClassVar[list[Binding]] = [
        Binding("escape", "close", "Close", show=False),
        Binding("r", "refresh", "Refresh", show=False),
    ]

    def __init__(
        self,
        service: MonitorService,
        maintenance: MaintenanceService,
        localizer: Localizer,
    ) -> None:
        super().__init__()
        self.service = service
        self.maintenance = maintenance
        self.localizer = localizer
        self.pids: list[int] = []
        self.controller = ProcessController(localizer)

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog maintenance-dialog memory-dialog"):
            yield Label(self.localizer("maintenance.memory.title"), classes="dialog-title")
            yield Static("", id="memory-summary")
            yield DataTable(cursor_type="row", zebra_stripes=True, id="memory-processes")
            with Horizontal(classes="dialog-actions maintenance-actions"):
                yield Button(self.localizer("maintenance.refresh"), id="memory-refresh")
                yield Button(
                    self.localizer("maintenance.release_cache"),
                    variant="primary",
                    id="memory-release",
                )
                yield Button(
                    self.localizer("maintenance.terminate_selected"),
                    id="memory-terminate",
                )
                yield Button(self.localizer("common.close"), id="memory-close")

    def on_mount(self) -> None:
        self.set_class(self.size.width < 100, "compact")
        self.query_one("#memory-processes", DataTable).add_columns(
            self.localizer("common.process"),
            self.localizer("common.pid"),
            self.localizer("column.rss"),
            self.localizer("column.used"),
        )
        self.action_refresh()

    def on_resize(self, event: events.Resize) -> None:
        self.set_class(event.size.width < 100, "compact")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "memory-close":
            self.action_close()
        elif event.button.id == "memory-refresh":
            self.action_refresh()
        elif event.button.id == "memory-release":
            self._confirm_release()
        elif event.button.id == "memory-terminate":
            self._confirm_terminate()

    def action_close(self) -> None:
        self.dismiss(None)

    def action_refresh(self) -> None:
        snapshot = self.service.latest
        if snapshot is None:
            return
        memory = snapshot.memory
        self.query_one("#memory-summary", Static).update(
            self.localizer(
                "maintenance.memory_summary",
                used=bytes_value(memory.used),
                total=bytes_value(memory.total),
                available=bytes_value(memory.available),
                cached=bytes_value(memory.cached),
                compressed=bytes_value(memory.compressed),
                pressure=self.localizer(f"pressure.{memory.pressure}"),
            )
        )
        processes = sorted(
            snapshot.processes, key=lambda process: process.memory_rss, reverse=True
        )[:15]
        table = self.query_one("#memory-processes", DataTable)
        table.clear(columns=False)
        self.pids = [process.pid for process in processes]
        for process in processes:
            table.add_row(
                process.name,
                str(process.pid),
                bytes_value(process.memory_rss),
                f"{process.memory_percent:.1f}%",
                key=str(process.pid),
            )

    def _confirm_release(self) -> None:
        def confirmed(value: bool) -> None:
            if value:
                self.run_worker(self._release_cache(), exclusive=True)

        self.app.push_screen(
            ConfirmScreen(
                self.localizer("maintenance.release_title"),
                self.localizer("maintenance.release_confirm"),
                self.localizer,
            ),
            confirmed,
        )

    async def _release_cache(self) -> None:
        button = self.query_one("#memory-release", Button)
        button.disabled = True
        try:
            ok, message = await asyncio.to_thread(self.maintenance.release_file_cache)
            if ok:
                self.notify(self.localizer("maintenance.release_done"))
            else:
                self.notify(
                    message or self.localizer("maintenance.release_unavailable"),
                    severity="warning",
                )
            await asyncio.sleep(0.3)
            if self.is_mounted:
                self.action_refresh()
        finally:
            if self.is_mounted:
                button.disabled = False

    def _confirm_terminate(self) -> None:
        table = self.query_one("#memory-processes", DataTable)
        if not 0 <= table.cursor_row < len(self.pids):
            self.notify(self.localizer("ui.select_process"), severity="warning")
            return
        snapshot = self.service.latest
        process = snapshot.process_by_pid(self.pids[table.cursor_row]) if snapshot else None
        if process is None:
            return

        def confirmed(value: bool) -> None:
            if value:
                result = self.controller.terminate(process)
                self.notify(
                    result.message,
                    severity="information" if result.ok else "error",
                )
                self.action_refresh()

        self.app.push_screen(
            ConfirmScreen(
                self.localizer("process.terminate_title"),
                self.localizer("process.terminate_prompt", name=process.name, pid=process.pid),
                self.localizer,
            ),
            confirmed,
        )
