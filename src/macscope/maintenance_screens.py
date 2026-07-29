from __future__ import annotations

import asyncio
import threading
from collections import defaultdict
from datetime import datetime
from typing import ClassVar

from rich.text import Text
from textual import events
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, DataTable, Label, Static

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

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog maintenance-dialog"):
            yield Label(self.localizer(f"maintenance.{self.mode}.title"), classes="dialog-title")
            with Horizontal(classes="maintenance-summary"):
                yield Static(self.localizer("maintenance.ready"), id="maintenance-status")
                yield Static("", id="maintenance-total")
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
        self.action_scan()

    def on_resize(self, event: events.Resize) -> None:
        self.set_class(event.size.width < 100, "compact")

    def on_unmount(self) -> None:
        self._cancel.set()

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        if event.data_table.id == "maintenance-results":
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
        self._cancel.set()
        self.dismiss(None)

    def action_toggle(self) -> None:
        table = self.query_one("#maintenance-results", DataTable)
        self._toggle_row(table.cursor_row)

    def action_select_all(self) -> None:
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
        self._set_buttons_disabled(True)
        self.query_one("#maintenance-status", Static).update(self.localizer("maintenance.cleaning"))
        try:
            result = await asyncio.to_thread(
                self.maintenance.cleanup,
                items,
                cache_mode=self.settings.cache_cleanup_mode,
            )
            if self.is_mounted:
                self._apply_cleanup_result(result)
        except Exception as exc:  # noqa: BLE001 - keep cleanup results visible.
            self.notify(str(exc), severity="error")
        finally:
            self._cleaning = False
            if self.is_mounted:
                self._set_buttons_disabled(False)

    def _apply_cleanup_result(self, result: CleanupResult) -> None:
        successful = result.deleted + result.trashed
        processed = {item.id for item in successful}
        processed_apps = {
            item.id for item in successful if item.kind is MaintenanceKind.APPLICATION
        }
        current_failures = {failure.item.id: failure for failure in result.errors}
        for item_id in processed:
            self.failures.pop(item_id, None)
        self.failures.update(current_failures)

        failed_children = {
            item.id
            for item in self.items
            if item.parent_id in processed_apps and item.id in self.failures
        }
        context_apps = {
            item.parent_id
            for item in self.items
            if item.id in failed_children and item.parent_id in processed_apps
        }
        removed = set(processed) - context_apps
        removed.update(
            item.id
            for item in self.items
            if item.parent_id in processed_apps and item.id not in failed_children
        )

        self.completed.difference_update(removed)
        self.completed.update(context_apps)
        self.items = [item for item in self.items if item.id not in removed]
        self.selected.difference_update(processed | removed)
        self.selected.update(
            item_id for item_id in current_failures if item_id not in self.completed
        )

        remaining_children = {item.parent_id for item in self.items if item.parent_id}
        finished_contexts = self.completed - remaining_children
        if finished_contexts:
            self.items = [item for item in self.items if item.id not in finished_contexts]
            self.completed.difference_update(finished_contexts)
            remaining_ids = {item.id for item in self.items}
            self.failures = {
                item_id: failure
                for item_id, failure in self.failures.items()
                if item_id in remaining_ids
            }
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
        if result.errors:
            self.notify(
                self.localizer("maintenance.cleanup_errors", count=len(result.errors)),
                severity="warning",
            )

    def _toggle_row(self, row: int) -> None:
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
                state = self.localizer("maintenance.moved_to_trash")
            if not state and item.category_key in {
                "maintenance.category.app_support",
                "maintenance.category.container",
            }:
                state = self.localizer("maintenance.user_data")
            name = f"  ↳ {item.name}" if item.parent_id else item.name
            table.add_row(
                Text(
                    "[✓]" if is_selected or is_completed else "[ ]",
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
        visible: list[MaintenanceItem] = []
        applications = [item for item in self.items if item.kind is MaintenanceKind.APPLICATION]
        related_by_parent: dict[str, list[MaintenanceItem]] = defaultdict(list)
        for item in self.items:
            if item.parent_id:
                related_by_parent[item.parent_id].append(item)
        for application in applications:
            visible.append(application)
            if application.id in self.selected or application.id in self.completed:
                visible.extend(related_by_parent[application.id])
        return visible

    def _selectable_ids(self) -> set[str]:
        if self.mode == "uninstall":
            return {
                item.id
                for item in self.items
                if item.kind is MaintenanceKind.APPLICATION
                and item.id not in self.completed
                and not item.blocked_reason
            }
        if self.mode == "duplicates":
            grouped: dict[str, list[MaintenanceItem]] = defaultdict(list)
            for item in self.items:
                grouped[item.group].append(item)
            return {
                item.id
                for group_items in grouped.values()
                for item in group_items[1:]
                if not item.blocked_reason
            }
        return {item.id for item in self.items if not item.blocked_reason}

    def _select_all_label(self) -> str:
        key = (
            "maintenance.select_all_apps" if self.mode == "uninstall" else "maintenance.select_all"
        )
        return self.localizer(key)

    def _update_action_state(self, selected_size: int | None = None) -> None:
        if not self.is_mounted:
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
        self._update_action_state()


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
