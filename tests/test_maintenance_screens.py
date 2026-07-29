from __future__ import annotations

import plistlib

import pytest
from textual.widgets import Button, DataTable, ProgressBar

from macscope.app import MacScopeApp
from macscope.maintenance import CleanupFailureCode, MaintenanceKind, MaintenanceService
from macscope.maintenance_screens import MaintenanceScreen, UninstallDetailsScreen
from macscope.settings import SettingsStore


@pytest.mark.asyncio
async def test_uninstaller_opens_single_app_review_with_related_data(
    tmp_path,
    monkeypatch,
) -> None:
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
    external_copy = tmp_path / "workspace/Example.app"
    monkeypatch.setattr(
        app.maintenance,
        "find_application_copies",
        lambda bundle_id, excluding=None: (external_copy,),
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
        assert str(screen.query_one(DataTable).get_row_at(0)[0]) == " › "
        assert not screen.query_one("#maintenance-clean", Button).display
        assert not screen.query_one("#maintenance-select-all", Button).display

        screen._toggle_row(0)
        await pilot.pause(0.2)
        details = app.screen
        assert isinstance(details, UninstallDetailsScreen)
        assert details.application == application
        assert details.related == (related,)
        assert details.other_copies == (external_copy,)
        assert details.selected == {application.id, related.id}
        warning = details.query_one("#uninstall-copy-warning")
        assert warning.has_class("visible")
        assert str(external_copy) in str(warning.render())
        table = details.query_one("#uninstall-items", DataTable)
        assert str(table.get_row_at(0)[0]) == "[✓]"
        assert str(table.get_row_at(1)[0]) == "[✓]"

        details._toggle_row(1)
        assert details.selected == {application.id}
        details._toggle_row(0)
        assert details.selected == {application.id}


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
        await pilot.pause(0.2)
        details = app.screen
        assert isinstance(details, UninstallDetailsScreen)
        details._toggle_row(1)

        def fail_related(path: str) -> None:
            if path == str(related.path):
                raise PermissionError("operation not permitted")

        monkeypatch.setattr("macscope.maintenance.send2trash", fail_related)
        details._begin_cleanup()
        await pilot.pause(0.3)

        assert details.completed == {application.id}
        assert details.selected == {related.id}
        assert details.failures[related.id].code is CleanupFailureCode.PRIVACY_ACCESS
        assert str(details.query_one("#uninstall-confirm", Button).label) == "Retry 1"
        assert "Full Disk Access required" in str(
            details.query_one("#uninstall-items", DataTable).get_row_at(1)[3]
        )
        progress = details.query_one("#uninstall-progress", ProgressBar)
        assert progress.has_class("active")
        assert progress.progress == progress.total

        monkeypatch.setattr("macscope.maintenance.send2trash", lambda path: None)
        details._begin_cleanup()
        await pilot.pause(0.3)

        assert details.completed == {application.id, related.id}
        assert details.failures == {}
        assert details.selected == set()
        assert details.query_one("#uninstall-confirm", Button).disabled


@pytest.mark.asyncio
async def test_cleanup_keeps_completed_file_details_and_progress_visible(
    tmp_path,
    monkeypatch,
) -> None:
    log = tmp_path / "Library/Logs/example.log"
    log.parent.mkdir(parents=True)
    log.write_bytes(b"log")
    app = MacScopeApp(settings_store=SettingsStore(tmp_path / "settings.plist"))
    app.maintenance = MaintenanceService(home=tmp_path)
    monkeypatch.setattr("macscope.maintenance.send2trash", lambda path: None)

    async with app.run_test(size=(120, 42)) as pilot:
        await pilot.pause(0.2)
        await pilot.click("#tool-junk")
        await pilot.pause(0.3)
        screen = app.screen
        assert isinstance(screen, MaintenanceScreen)
        item = screen.items[0]

        await screen._clean([item])
        await pilot.pause()

        assert screen.items == [item]
        assert screen.completed == {item.id}
        assert screen.query_one("#maintenance-progress", ProgressBar).progress == 1
        row = screen.query_one("#maintenance-results", DataTable).get_row_at(0)
        assert "Moved to Trash" in str(row[3])
        assert str(item.path) in str(row[6])
