from __future__ import annotations

import plistlib

import pytest
from textual.widgets import Button, DataTable

from macscope.app import MacScopeApp
from macscope.maintenance import CleanupFailureCode, MaintenanceKind, MaintenanceService
from macscope.maintenance_screens import MaintenanceScreen
from macscope.settings import SettingsStore


@pytest.mark.asyncio
async def test_uninstaller_reveals_related_data_only_after_app_selection(tmp_path) -> None:
    applications = tmp_path / "Applications"
    app_path = applications / "Example.app"
    info = app_path / "Contents/Info.plist"
    info.parent.mkdir(parents=True)
    with info.open("wb") as handle:
        plistlib.dump({"CFBundleIdentifier": "com.example.Example"}, handle)
    cache = tmp_path / "Library/Caches/com.example.Example"
    cache.mkdir(parents=True)
    (cache / "data").write_bytes(b"cache")

    app = MacScopeApp(settings_store=SettingsStore(tmp_path / "settings.plist"))
    app.maintenance = MaintenanceService(
        home=tmp_path,
        application_roots=(applications,),
        scan_roots=(tmp_path / "Downloads",),
    )
    async with app.run_test(size=(120, 42)) as pilot:
        await pilot.pause(0.2)
        await pilot.click("#tool-uninstall")
        await pilot.pause(0.3)
        screen = app.screen
        assert isinstance(screen, MaintenanceScreen)
        application = next(
            item for item in screen.items if item.kind is MaintenanceKind.APPLICATION
        )
        related = next(item for item in screen.items if item.kind is MaintenanceKind.RESIDUE)
        assert screen.visible_items == [application]
        assert str(screen.query_one(DataTable).get_row_at(0)[0]) == "[ ]"
        assert screen.query_one("#maintenance-clean", Button).disabled

        screen._toggle_row(0)
        await pilot.pause()
        assert screen.visible_items == [application, related]
        assert str(screen.query_one(DataTable).get_row_at(0)[0]) == "[✓]"
        assert not screen.query_one("#maintenance-clean", Button).disabled

        screen._toggle_row(1)
        assert screen.selected == {application.id, related.id}

        screen._toggle_row(0)
        assert screen.selected == set()
        assert screen.visible_items == [application]
        assert screen.query_one("#maintenance-clean", Button).disabled


@pytest.mark.asyncio
async def test_uninstaller_keeps_failed_related_data_for_retry(
    tmp_path,
    monkeypatch,
) -> None:
    applications = tmp_path / "Applications"
    app_path = applications / "Example.app"
    info = app_path / "Contents/Info.plist"
    info.parent.mkdir(parents=True)
    with info.open("wb") as handle:
        plistlib.dump({"CFBundleIdentifier": "com.example.Example"}, handle)
    container = tmp_path / "Library/Containers/com.example.Example"
    container.mkdir(parents=True)
    (container / "data").write_bytes(b"user data")

    app = MacScopeApp(settings_store=SettingsStore(tmp_path / "settings.plist"))
    app.maintenance = MaintenanceService(
        home=tmp_path,
        application_roots=(applications,),
        scan_roots=(tmp_path / "Downloads",),
    )
    monkeypatch.setattr(app.maintenance, "_application_running", lambda path: False)
    async with app.run_test(size=(120, 42)) as pilot:
        await pilot.pause(0.2)
        await pilot.click("#tool-uninstall")
        await pilot.pause(0.3)
        screen = app.screen
        assert isinstance(screen, MaintenanceScreen)
        application = next(
            item for item in screen.items if item.kind is MaintenanceKind.APPLICATION
        )
        related = next(item for item in screen.items if item.kind is MaintenanceKind.RESIDUE)
        screen._toggle_row(0)
        screen._toggle_row(1)

        def fail_related(path: str) -> None:
            if path == str(related.path):
                raise PermissionError("operation not permitted")

        monkeypatch.setattr("macscope.maintenance.send2trash", fail_related)
        result = screen.maintenance.cleanup((application, related))
        screen._apply_cleanup_result(result)
        await pilot.pause()

        assert screen.items == [application, related]
        assert screen.completed == {application.id}
        assert screen.selected == {related.id}
        assert screen.failures[related.id].code is CleanupFailureCode.PRIVACY_ACCESS
        assert str(screen.query_one("#maintenance-clean", Button).label) == "Retry 1"
        assert "Full Disk Access required" in str(screen.query_one(DataTable).get_row_at(1)[3])

        screen._toggle_row(0)
        assert screen.selected == {related.id}

        monkeypatch.setattr("macscope.maintenance.send2trash", lambda path: None)
        retry = screen.maintenance.cleanup((related,))
        screen._apply_cleanup_result(retry)
        await pilot.pause()

        assert screen.items == []
        assert screen.visible_items == []
        assert screen.completed == set()
        assert screen.selected == set()
