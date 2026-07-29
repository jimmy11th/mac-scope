from __future__ import annotations

from collections.abc import Callable, Iterable
from pathlib import Path
from typing import ClassVar, cast

from textual.app import ComposeResult
from textual.binding import Binding
from textual.color import Color
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import Button, Input, Label, Select, Static, Switch

from macscope.i18n import Localizer
from macscope.screens import PromptScreen
from macscope.settings import Settings, validate_settings
from macscope.themes import (
    COLOR_PATTERN,
    COLOR_TOKENS,
    ThemeDefinition,
    ThemeRepository,
    contrast_ratio,
)

PreviewThemeId = Callable[[str], None]
PreviewColors = Callable[[dict[str, str], str], None]


class ThemeEditorScreen(ModalScreen[ThemeDefinition | None]):
    BINDINGS: ClassVar[list[Binding]] = [Binding("escape", "cancel", "Cancel", show=False)]

    def __init__(
        self,
        repository: ThemeRepository,
        base_theme_id: str,
        localizer: Localizer,
        preview_colors: PreviewColors,
        restore_preview: Callable[[], None],
    ) -> None:
        super().__init__()
        self.repository = repository
        self.base_theme_id = base_theme_id
        self.localizer = localizer
        self.preview_colors = preview_colors
        self.restore_preview = restore_preview
        base = repository.get(base_theme_id)
        self.editing_id = base.id if not base.builtin else ""
        self.initial_name = base.name if self.editing_id else f"{base.name} Custom"
        self.initial_mode = base.mode
        self.theme_colors = repository.resolved_colors(base_theme_id)

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog theme-editor-dialog"):
            yield Label(self.localizer("theme.editor"), classes="dialog-title")
            with Horizontal(classes="preference-row theme-meta-row"):
                yield Label(self.localizer("theme.name"), classes="preference-label")
                yield Input(value=self.initial_name, id="theme-name")
                yield Select(
                    [
                        (self.localizer("theme.mode_dark"), "dark"),
                        (self.localizer("theme.mode_light"), "light"),
                    ],
                    value=self.initial_mode,
                    allow_blank=False,
                    compact=True,
                    id="theme-mode",
                )
            yield Static(id="contrast-status")
            with VerticalScroll(classes="theme-color-list"):
                for token in COLOR_TOKENS:
                    with Horizontal(classes="color-row"):
                        yield Label(self.localizer(f"color.{token}"), classes="color-label")
                        yield Static("  ", id=f"swatch-{token}", classes="color-swatch")
                        yield Input(value=self.theme_colors[token], id=f"color-{token}")
            with Horizontal(classes="dialog-actions"):
                yield Button(self.localizer("common.cancel"), id="theme-cancel")
                yield Button(
                    self.localizer("common.save"),
                    variant="primary",
                    id="theme-save",
                )

    def on_mount(self) -> None:
        self._refresh_preview()

    def on_input_changed(self, event: Input.Changed) -> None:
        if event.input.id and event.input.id.startswith("color-"):
            self._refresh_preview()

    def on_select_changed(self, event: Select.Changed) -> None:
        if event.select.id == "theme-mode":
            self._refresh_preview()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "theme-cancel":
            self.action_cancel()
            return
        if event.button.id != "theme-save":
            return
        name = self.query_one("#theme-name", Input).value.strip()
        colors = self._collect_colors()
        if not name:
            self.notify(self.localizer("theme.invalid_name"), severity="error")
            return
        if colors is None:
            self.notify(self.localizer("theme.invalid_color"), severity="error")
            return
        mode = cast(str, self.query_one("#theme-mode", Select).value)
        try:
            definition = self.repository.save_custom(
                name, colors, theme_id=self.editing_id, mode=mode
            )
        except (OSError, TypeError, ValueError) as exc:
            self.notify(
                str(exc),
                title=self.localizer("theme.save_failed"),
                severity="error",
            )
            return
        self.dismiss(definition)

    def action_cancel(self) -> None:
        self.restore_preview()
        self.dismiss(None)

    def _collect_colors(self) -> dict[str, str] | None:
        colors: dict[str, str] = {}
        for token in COLOR_TOKENS:
            value = self.query_one(f"#color-{token}", Input).value.strip().upper()
            if not COLOR_PATTERN.fullmatch(value):
                return None
            colors[token] = value
        return colors

    def _refresh_preview(self) -> None:
        colors = self._collect_colors()
        for token in COLOR_TOKENS:
            value = self.query_one(f"#color-{token}", Input).value.strip()
            swatch = self.query_one(f"#swatch-{token}", Static)
            if COLOR_PATTERN.fullmatch(value):
                swatch.styles.background = Color.parse(value)
            else:
                swatch.styles.background = Color.parse("#000000")
        if colors is None:
            self.query_one("#contrast-status", Static).update(self.localizer("theme.invalid_color"))
            return
        ratio = contrast_ratio(colors["text"], colors["background"])
        key = "theme.contrast_ok" if ratio >= 4.5 else "theme.contrast_low"
        self.query_one("#contrast-status", Static).update(self.localizer(key, ratio=ratio))
        mode = cast(str, self.query_one("#theme-mode", Select).value)
        self.preview_colors(colors, mode)


class SettingsScreen(ModalScreen[Settings | None]):
    BINDINGS: ClassVar[list[Binding]] = [Binding("escape", "cancel", "Cancel", show=False)]

    def __init__(
        self,
        settings: Settings,
        repository: ThemeRepository,
        localizer: Localizer,
        interfaces: Iterable[str],
        preview_theme_id: PreviewThemeId,
        preview_colors: PreviewColors,
        restore_preview: Callable[[], None],
    ) -> None:
        super().__init__()
        self.settings = settings
        self.repository = repository
        self.localizer = localizer
        self.interfaces = tuple(interfaces)
        self.preview_theme_id = preview_theme_id
        self.preview_colors = preview_colors
        self.restore_preview = restore_preview

    def compose(self) -> ComposeResult:
        with Vertical(classes="dialog settings-dialog"):
            yield Label(self.localizer("settings.title"), classes="dialog-title")
            with VerticalScroll(classes="settings-body"):
                yield Label(self.localizer("settings.appearance"), classes="settings-section")
                yield from self._select_row(
                    "settings.language",
                    "setting-language",
                    [("English", "en"), ("简体中文", "zh-CN")],
                    self.settings.language,
                )
                yield from self._select_row(
                    "settings.theme",
                    "setting-theme",
                    self._theme_options(),
                    self.settings.theme,
                )
                with Horizontal(classes="theme-actions"):
                    yield Button(self.localizer("settings.customize"), id="customize-theme")
                    yield Button(self.localizer("settings.import"), id="import-theme")
                    yield Button(self.localizer("settings.export"), id="export-theme")
                yield from self._select_row(
                    "settings.temperature",
                    "setting-temperature",
                    [
                        (self.localizer("settings.celsius"), "celsius"),
                        (self.localizer("settings.fahrenheit"), "fahrenheit"),
                    ],
                    self.settings.temperature_unit,
                )

                yield Label(self.localizer("settings.general"), classes="settings-section")
                yield from self._select_row(
                    "settings.refresh",
                    "setting-refresh",
                    [(f"{value:g} s", value) for value in (0.5, 1.0, 2.0, 5.0)],
                    self.settings.refresh_interval,
                )
                with Horizontal(classes="preference-row"):
                    yield Label(self.localizer("settings.rows"), classes="preference-label")
                    yield Input(
                        value=str(self.settings.default_top_rows),
                        type="integer",
                        id="setting-rows",
                    )
                yield from self._select_row(
                    "settings.default_sort",
                    "setting-sort-key",
                    [
                        (self.localizer("sort.process"), "process"),
                        (self.localizer("sort.pid"), "pid"),
                        (self.localizer("sort.cpu"), "cpu"),
                        (self.localizer("sort.memory"), "memory"),
                        (self.localizer("sort.disk_read"), "disk_read"),
                        (self.localizer("sort.disk_write"), "disk_write"),
                        (self.localizer("sort.network_down"), "network_down"),
                        (self.localizer("sort.network_up"), "network_up"),
                        (self.localizer("sort.threads"), "threads"),
                        (self.localizer("sort.runtime"), "runtime"),
                    ],
                    self.settings.default_sort_key,
                )
                yield from self._select_row(
                    "settings.sort_direction",
                    "setting-sort-direction",
                    [
                        (self.localizer("settings.descending"), True),
                        (self.localizer("settings.ascending"), False),
                    ],
                    self.settings.default_sort_descending,
                )
                yield from self._select_row(
                    "settings.smoothing",
                    "setting-smoothing",
                    [
                        (self.localizer("settings.off"), 0.0),
                        ("3 s", 3.0),
                        ("5 s", 5.0),
                    ],
                    self.settings.smoothing_seconds,
                )
                interface_options = [(self.localizer("settings.automatic"), "auto")] + [
                    (name, name) for name in self.interfaces
                ]
                selected_interface = (
                    self.settings.network_interface
                    if self.settings.network_interface in {value for _, value in interface_options}
                    else "auto"
                )
                yield from self._select_row(
                    "settings.interface",
                    "setting-interface",
                    interface_options,
                    selected_interface,
                )
                yield from self._switch_row(
                    "settings.show_self", "setting-show-self", self.settings.show_self
                )
                yield from self._switch_row(
                    "settings.inactive",
                    "setting-inactive",
                    self.settings.include_inactive_io,
                )
                yield Label(self.localizer("settings.maintenance"), classes="settings-section")
                yield from self._select_row(
                    "settings.cache_cleanup",
                    "setting-cache-cleanup",
                    [
                        (self.localizer("settings.move_to_trash"), "trash"),
                        (self.localizer("settings.delete_caches"), "delete"),
                    ],
                    self.settings.cache_cleanup_mode,
                )
                yield from self._select_row(
                    "settings.large_threshold",
                    "setting-large-threshold",
                    [
                        ("100 MB", 100),
                        ("500 MB", 500),
                        ("1 GB", 1024),
                        ("5 GB", 5120),
                    ],
                    self.settings.large_file_threshold_mb,
                )
                yield from self._select_row(
                    "settings.duplicate_minimum",
                    "setting-duplicate-minimum",
                    [("1 MB", 1), ("10 MB", 10), ("100 MB", 100), ("500 MB", 500)],
                    self.settings.duplicate_minimum_size_mb,
                )
                with Horizontal(classes="preference-row scan-roots-row"):
                    yield Label(self.localizer("settings.scan_folders"), classes="preference-label")
                    yield Input(
                        value=", ".join(self.settings.maintenance_scan_roots),
                        id="setting-scan-roots",
                    )
            with Horizontal(classes="dialog-actions settings-actions"):
                yield Button(self.localizer("settings.reset"), id="settings-reset")
                yield Button(self.localizer("common.cancel"), id="settings-cancel")
                yield Button(
                    self.localizer("common.save"),
                    variant="primary",
                    id="settings-save",
                )

    def _select_row(
        self,
        label_key: str,
        widget_id: str,
        options: list[tuple[str, object]],
        value: object,
    ):
        with Horizontal(classes="preference-row"):
            yield Label(self.localizer(label_key), classes="preference-label")
            yield Select(
                options,
                value=value,
                allow_blank=False,
                compact=True,
                id=widget_id,
            )

    def _switch_row(self, label_key: str, widget_id: str, value: bool):
        with Horizontal(classes="preference-row"):
            yield Label(self.localizer(label_key), classes="preference-label")
            yield Switch(value=value, id=widget_id)

    def _theme_options(self) -> list[tuple[str, str]]:
        return [(theme.name, theme.id) for theme in self.repository.all()]

    def on_select_changed(self, event: Select.Changed) -> None:
        if event.select.id == "setting-theme" and isinstance(event.value, str):
            self.preview_theme_id(event.value)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        button_id = event.button.id
        if button_id == "settings-cancel":
            self.action_cancel()
        elif button_id == "settings-save":
            self._save()
        elif button_id == "settings-reset":
            self._set_controls(Settings())
        elif button_id == "customize-theme":
            self._customize_theme()
        elif button_id == "import-theme":
            self._import_theme()
        elif button_id == "export-theme":
            self._export_theme()

    def action_cancel(self) -> None:
        self.restore_preview()
        self.dismiss(None)

    def _save(self) -> None:
        try:
            rows = int(self.query_one("#setting-rows", Input).value)
        except ValueError:
            self.notify(self.localizer("settings.rows_integer"), severity="error")
            return
        if not 1 <= rows <= 20:
            self.notify(self.localizer("settings.rows_range"), severity="error")
            return
        scan_roots = tuple(
            value.strip()
            for value in self.query_one("#setting-scan-roots", Input).value.split(",")
            if value.strip()
        )
        if not scan_roots:
            self.notify(self.localizer("settings.scan_folders_required"), severity="error")
            return
        settings = validate_settings(
            Settings(
                language=cast(str, self.query_one("#setting-language", Select).value),
                theme=cast(str, self.query_one("#setting-theme", Select).value),
                refresh_interval=cast(float, self.query_one("#setting-refresh", Select).value),
                default_top_rows=rows,
                temperature_unit=cast(str, self.query_one("#setting-temperature", Select).value),
                smoothing_seconds=cast(float, self.query_one("#setting-smoothing", Select).value),
                network_interface=cast(str, self.query_one("#setting-interface", Select).value),
                show_self=self.query_one("#setting-show-self", Switch).value,
                include_inactive_io=self.query_one("#setting-inactive", Switch).value,
                cache_cleanup_mode=cast(
                    str, self.query_one("#setting-cache-cleanup", Select).value
                ),
                large_file_threshold_mb=cast(
                    int, self.query_one("#setting-large-threshold", Select).value
                ),
                duplicate_minimum_size_mb=cast(
                    int, self.query_one("#setting-duplicate-minimum", Select).value
                ),
                default_sort_key=cast(str, self.query_one("#setting-sort-key", Select).value),
                default_sort_descending=cast(
                    bool, self.query_one("#setting-sort-direction", Select).value
                ),
                maintenance_scan_roots=scan_roots,
            )
        )
        self.dismiss(settings)

    def _set_controls(self, settings: Settings) -> None:
        self.query_one("#setting-language", Select).value = settings.language
        self.query_one("#setting-theme", Select).value = settings.theme
        self.query_one("#setting-refresh", Select).value = settings.refresh_interval
        self.query_one("#setting-rows", Input).value = str(settings.default_top_rows)
        self.query_one("#setting-temperature", Select).value = settings.temperature_unit
        self.query_one("#setting-smoothing", Select).value = settings.smoothing_seconds
        self.query_one("#setting-interface", Select).value = settings.network_interface
        self.query_one("#setting-show-self", Switch).value = settings.show_self
        self.query_one("#setting-inactive", Switch).value = settings.include_inactive_io
        self.query_one("#setting-cache-cleanup", Select).value = settings.cache_cleanup_mode
        self.query_one("#setting-large-threshold", Select).value = settings.large_file_threshold_mb
        self.query_one(
            "#setting-duplicate-minimum", Select
        ).value = settings.duplicate_minimum_size_mb
        self.query_one("#setting-sort-key", Select).value = settings.default_sort_key
        self.query_one("#setting-sort-direction", Select).value = settings.default_sort_descending
        self.query_one("#setting-scan-roots", Input).value = ", ".join(
            settings.maintenance_scan_roots
        )

    def _customize_theme(self) -> None:
        selected = cast(str, self.query_one("#setting-theme", Select).value)

        def saved(definition: ThemeDefinition | None) -> None:
            if definition is None:
                self.preview_theme_id(selected)
                return
            theme_select = self.query_one("#setting-theme", Select)
            theme_select.set_options(self._theme_options())
            theme_select.value = definition.id
            self.preview_theme_id(definition.id)
            self.notify(self.localizer("theme.saved", name=definition.name))

        self.app.push_screen(
            ThemeEditorScreen(
                self.repository,
                selected,
                self.localizer,
                self.preview_colors,
                lambda: self.preview_theme_id(selected),
            ),
            saved,
        )

    def _import_theme(self) -> None:
        def imported(value: str | None) -> None:
            if not value:
                return
            try:
                definition = self.repository.import_file(Path(value.strip(" '\"")))
            except (OSError, TypeError, ValueError) as exc:
                self.notify(
                    str(exc),
                    title=self.localizer("theme.import_failed"),
                    severity="error",
                )
                return
            select = self.query_one("#setting-theme", Select)
            select.set_options(self._theme_options())
            select.value = definition.id
            self.preview_theme_id(definition.id)
            self.notify(self.localizer("theme.imported", name=definition.name))

        self.app.push_screen(
            PromptScreen(
                self.localizer("theme.import_title"),
                self.localizer("theme.import_prompt"),
                localizer=self.localizer,
            ),
            imported,
        )

    def _export_theme(self) -> None:
        selected = cast(str, self.query_one("#setting-theme", Select).value)
        default = str(Path.home() / "Desktop" / f"{selected}.macscope-theme.json")

        def exported(value: str | None) -> None:
            if not value:
                return
            try:
                path = self.repository.export_file(selected, Path(value.strip(" '\"")))
            except (OSError, TypeError, ValueError) as exc:
                self.notify(
                    str(exc),
                    title=self.localizer("theme.export_failed"),
                    severity="error",
                )
                return
            self.notify(self.localizer("theme.exported", path=path))

        self.app.push_screen(
            PromptScreen(
                self.localizer("theme.export_title"),
                self.localizer("theme.export_prompt"),
                default,
                self.localizer,
            ),
            exported,
        )
