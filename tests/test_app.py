from __future__ import annotations

import pytest
from rich.text import Text
from textual.widgets import DataTable, Input, Label, Select

from macscope.app import MacScopeApp
from macscope.maintenance import MaintenanceService
from macscope.maintenance_screens import MaintenanceScreen, MemoryReliefScreen
from macscope.models import ProcessSort
from macscope.preferences import SettingsScreen, ThemeEditorScreen
from macscope.screens import HelpScreen, SearchScreen
from macscope.settings import SettingsStore
from macscope.widgets import ToolsPanel, UnifiedProcessPanel


@pytest.mark.asyncio
async def test_dashboard_and_modal_navigation(tmp_path) -> None:
    app = MacScopeApp(settings_store=SettingsStore(tmp_path / "settings.plist"))
    async with app.run_test(size=(120, 40)) as pilot:
        await pilot.pause(1.2)
        assert app.service.latest is not None
        assert app.top_limit == 5
        assert len(app.query(UnifiedProcessPanel)) == 1
        assert len(app.query(ToolsPanel)) == 1
        assert app.query_one(UnifiedProcessPanel).display
        assert app.query_one(ToolsPanel).display

        await pilot.press("question_mark")
        assert isinstance(app.screen, HelpScreen)
        await pilot.press("escape")

        await pilot.press("slash")
        assert isinstance(app.screen, SearchScreen)
        await pilot.press("escape")

        await pilot.press("l")
        await pilot.press("7", "enter")
        assert app.top_limit == 7
        assert app.query_one(UnifiedProcessPanel).top_limit == 7


@pytest.mark.asyncio
async def test_compact_layout_uses_top_and_tools_tabs(tmp_path) -> None:
    app = MacScopeApp(settings_store=SettingsStore(tmp_path / "settings.plist"))
    async with app.run_test(size=(82, 40)) as pilot:
        await pilot.pause()
        assert app.screen.has_class("compact")
        await pilot.press("2")
        panel = app.query_one(UnifiedProcessPanel)
        assert panel.display
        assert not app.query_one(ToolsPanel).display
        assert panel.sort_key is ProcessSort.MEMORY
        assert panel.descending

        app.query_one("#view-tabs").active = "tab-tools"
        await pilot.pause()
        assert not panel.display
        assert app.query_one(ToolsPanel).display


@pytest.mark.asyncio
async def test_settings_apply_immediately_and_persist(tmp_path) -> None:
    store = SettingsStore(tmp_path / "settings.plist")
    app = MacScopeApp(settings_store=store)
    async with app.run_test(size=(120, 44)) as pilot:
        await pilot.pause(0.2)
        await pilot.press("s")
        assert isinstance(app.screen, SettingsScreen)
        old_timer = app._refresh_timer

        app.screen.query_one("#setting-language", Select).value = "zh-CN"
        app.screen.query_one("#setting-theme", Select).value = "paper-light"
        app.screen.query_one("#setting-refresh", Select).value = 2.0
        app.screen.query_one("#setting-temperature", Select).value = "fahrenheit"
        app.screen.query_one("#setting-rows", Input).value = "7"
        app.screen.query_one("#setting-cache-cleanup", Select).value = "delete"
        app.screen.query_one("#setting-large-threshold", Select).value = 1024
        app.screen.query_one("#setting-duplicate-minimum", Select).value = 100
        app.screen.query_one("#setting-sort-key", Select).value = "memory"
        app.screen.query_one("#setting-sort-direction", Select).value = False
        app.screen.query_one("#setting-scan-roots", Input).value = str(tmp_path / "Scan")
        await pilot.click("#settings-save")
        await pilot.pause(0.2)

        assert app.settings.language == "zh-CN"
        assert app.settings.theme == "paper-light"
        assert app.settings.temperature_unit == "fahrenheit"
        assert app.settings.refresh_interval == 2.0
        assert app.settings.cache_cleanup_mode == "delete"
        assert app.settings.large_file_threshold_mb == 1024
        assert app.settings.duplicate_minimum_size_mb == 100
        assert app.settings.default_sort_key == "memory"
        assert app.settings.default_sort_descending is False
        assert app.settings.maintenance_scan_roots == (str(tmp_path / "Scan"),)
        assert app.top_limit == 7
        assert app.theme == "macscope-paper-light"
        assert app._refresh_timer is not old_timer
        assert app.service.network_sampler.interval == 2.0
        assert app.query_one(UnifiedProcessPanel).sort_key is ProcessSort.MEMORY
        assert not app.query_one(UnifiedProcessPanel).descending
        assert app.maintenance.scan_roots == (tmp_path / "Scan",)
        assert store.load() == app.settings
        assert "前 7" in str(app.query_one("#process-panel .panel-title").render())
        assert app.active_bindings["s"].binding.description == "设置"

        await pilot.press("slash")
        assert isinstance(app.screen, SearchScreen)
        assert str(app.screen.query_one(".dialog-title", Label).render()) == "搜索进程"
        await pilot.press("escape")


@pytest.mark.asyncio
async def test_unified_table_header_sorting_and_tool_navigation(tmp_path) -> None:
    app = MacScopeApp(settings_store=SettingsStore(tmp_path / "settings.plist"))
    app.maintenance = MaintenanceService(
        home=tmp_path,
        application_roots=(tmp_path / "Applications",),
        scan_roots=(tmp_path / "Downloads",),
    )
    async with app.run_test(size=(120, 42)) as pilot:
        await pilot.pause(0.2)
        panel = app.query_one(UnifiedProcessPanel)
        table = panel.query_one(DataTable)
        memory_key = next(key for key in table.columns if key.value == "memory")

        table.post_message(DataTable.HeaderSelected(table, memory_key, 3, Text("RSS")))
        await pilot.pause()
        assert panel.sort_key is ProcessSort.MEMORY
        assert panel.descending

        table.post_message(DataTable.HeaderSelected(table, memory_key, 3, Text("RSS")))
        await pilot.pause()
        assert not panel.descending

        await pilot.click("#tool-junk")
        assert isinstance(app.screen, MaintenanceScreen)
        assert app.screen.mode == "junk"
        await pilot.press("escape")

        await pilot.click("#tool-memory")
        assert isinstance(app.screen, MemoryReliefScreen)
        await pilot.press("escape")


@pytest.mark.asyncio
async def test_theme_editor_live_preview_cancel_and_save(tmp_path) -> None:
    app = MacScopeApp(settings_store=SettingsStore(tmp_path / "settings.plist"))
    async with app.run_test(size=(120, 44)) as pilot:
        await pilot.pause(0.2)
        original_accent = app.theme_colors["accent"]
        await pilot.press("s")
        await pilot.click("#customize-theme")
        assert isinstance(app.screen, ThemeEditorScreen)

        app.screen.query_one("#color-accent", Input).value = "#123456"
        await pilot.pause(0.1)
        assert app.theme_colors["accent"] == "#123456"
        await pilot.press("escape")
        assert isinstance(app.screen, SettingsScreen)
        assert app.theme_colors["accent"] == original_accent

        await pilot.click("#customize-theme")
        app.screen.query_one("#theme-name", Input).value = "Ocean Test"
        app.screen.query_one("#color-accent", Input).value = "#123456"
        await pilot.click("#theme-save")
        await pilot.pause(0.1)
        assert isinstance(app.screen, SettingsScreen)
        assert app.screen.query_one("#setting-theme", Select).value == "ocean-test"
        assert (tmp_path / "themes" / "ocean-test.macscope-theme.json").exists()
        await pilot.click("#settings-save")
        await pilot.pause(0.1)
        assert app.settings.theme == "ocean-test"
        assert SettingsStore(tmp_path / "settings.plist").load().theme == "ocean-test"
