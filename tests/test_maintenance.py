from __future__ import annotations

import os
import plistlib
from dataclasses import replace
from pathlib import Path

from macscope.maintenance import CleanupFailureCode, MaintenanceKind, MaintenanceService


def write_bytes(path: Path, size: int, byte: bytes = b"x") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(byte * size)


def test_large_file_scan_stays_in_roots_and_skips_symlinks(tmp_path) -> None:
    downloads = tmp_path / "Downloads"
    outside = tmp_path / "outside.bin"
    expected = downloads / "large.bin"
    write_bytes(expected, 1024)
    write_bytes(outside, 2048)
    os.symlink(outside, downloads / "outside-link")
    service = MaintenanceService(home=tmp_path, scan_roots=(downloads,))

    result = service.scan_large_files(0)

    assert {item.path for item in result.items} == {expected}
    assert all(item.path.is_relative_to(downloads) for item in result.items)


def test_changed_file_identity_blocks_cleanup(tmp_path) -> None:
    downloads = tmp_path / "Downloads"
    path = downloads / "large.bin"
    write_bytes(path, 1024)
    service = MaintenanceService(home=tmp_path, scan_roots=(downloads,))
    item = service.scan_large_files(0).items[0]
    path.write_bytes(b"changed")

    result = service.cleanup((item,))

    assert result.trashed == ()
    assert result.deleted == ()
    assert result.errors[0].code is CleanupFailureCode.CHANGED
    assert path.exists()


def test_cache_mode_only_permanently_deletes_rebuildable_cache(tmp_path, monkeypatch) -> None:
    cache = tmp_path / "Library/Caches/example/cache.bin"
    log = tmp_path / "Library/Logs/example.log"
    write_bytes(cache, 128)
    write_bytes(log, 64)
    service = MaintenanceService(home=tmp_path)
    result = service.scan_junk()
    cache_item = next(item for item in result.items if item.kind is MaintenanceKind.CACHE)
    log_item = next(item for item in result.items if item.kind is MaintenanceKind.LOG)
    trashed: list[str] = []
    monkeypatch.setattr("macscope.maintenance.send2trash", trashed.append)

    cleanup = service.cleanup((cache_item, log_item), cache_mode="delete")

    assert cleanup.deleted == (cache_item,)
    assert cleanup.trashed == (log_item,)
    assert not cache_item.path.exists()
    assert trashed == [str(log_item.path)]


def test_trash_mode_sends_cache_to_trash(tmp_path, monkeypatch) -> None:
    cache = tmp_path / "Library/Caches/example"
    write_bytes(cache, 32)
    service = MaintenanceService(home=tmp_path)
    item = service.scan_junk().items[0]
    trashed: list[str] = []
    monkeypatch.setattr("macscope.maintenance.send2trash", trashed.append)

    result = service.cleanup((item,), cache_mode="trash")

    assert result.trashed == (item,)
    assert result.deleted == ()
    assert trashed == [str(item.path)]


def test_configured_external_scan_root_can_be_cleaned(tmp_path, monkeypatch) -> None:
    home = tmp_path / "home"
    external = tmp_path / "external"
    path = external / "large.bin"
    write_bytes(path, 1024)
    service = MaintenanceService(home=home, scan_roots=(external,))
    item = service.scan_large_files(0).items[0]
    trashed: list[str] = []
    monkeypatch.setattr("macscope.maintenance.send2trash", trashed.append)

    result = service.cleanup((item,))

    assert result.errors == ()
    assert result.trashed == (item,)
    assert trashed == [str(path)]


def test_application_residues_require_exact_bundle_identifier(tmp_path, monkeypatch) -> None:
    applications = tmp_path / "Applications"
    app = applications / "Example.app"
    info = app / "Contents/Info.plist"
    info.parent.mkdir(parents=True)
    with info.open("wb") as handle:
        plistlib.dump(
            {"CFBundleIdentifier": "com.example.Example", "CFBundleName": "Example"},
            handle,
        )
    exact = tmp_path / "Library/Caches/com.example.Example"
    similar = tmp_path / "Library/Caches/com.example.Example.beta"
    write_bytes(exact / "cache", 10)
    write_bytes(similar / "cache", 10)
    service = MaintenanceService(
        home=tmp_path,
        application_roots=(applications,),
    )
    monkeypatch.setattr(service, "_application_running", lambda path: False)

    result = service.scan_applications()

    assert app in {item.path for item in result.items}
    assert exact in {item.path for item in result.items}
    assert similar not in {item.path for item in result.items}
    app_item = next(item for item in result.items if item.path == app)
    residue = next(item for item in result.items if item.path == exact)
    assert residue.parent_id == app_item.id
    assert residue.category_key == "maintenance.category.app_cache"


def test_running_application_is_blocked(tmp_path, monkeypatch) -> None:
    applications = tmp_path / "Applications"
    app = applications / "Example.app"
    (app / "Contents").mkdir(parents=True)
    service = MaintenanceService(home=tmp_path, application_roots=(applications,))
    monkeypatch.setattr(service, "_application_running", lambda path: True)

    item = next(
        item
        for item in service.scan_applications().items
        if item.kind is MaintenanceKind.APPLICATION
    )

    assert item.blocked_reason == "maintenance.running"


def test_application_permission_failure_requires_administrator(
    tmp_path,
    monkeypatch,
) -> None:
    applications = tmp_path / "Applications"
    app = applications / "Example.app"
    (app / "Contents").mkdir(parents=True)
    service = MaintenanceService(home=tmp_path, application_roots=(applications,))
    monkeypatch.setattr(service, "_application_running", lambda path: False)
    item = next(
        item
        for item in service.scan_applications().items
        if item.kind is MaintenanceKind.APPLICATION
    )
    item = replace(item, path=Path("/Applications/Example.app"))
    monkeypatch.setattr(service, "_validate_cleanup_item", lambda selected: None)

    def deny_trash(path: str) -> None:
        raise OSError("Insufficient access privileges for operation")

    monkeypatch.setattr("macscope.maintenance.send2trash", deny_trash)

    result = service.cleanup((item,))

    assert result.errors[0].code is CleanupFailureCode.ADMIN_REQUIRED


def test_container_permission_failure_requires_full_disk_access(
    tmp_path,
    monkeypatch,
) -> None:
    applications = tmp_path / "Applications"
    app = applications / "Example.app"
    info = app / "Contents/Info.plist"
    info.parent.mkdir(parents=True)
    with info.open("wb") as handle:
        plistlib.dump({"CFBundleIdentifier": "com.example.Example"}, handle)
    container = tmp_path / "Library/Containers/com.example.Example"
    write_bytes(container / "data", 32)
    service = MaintenanceService(home=tmp_path, application_roots=(applications,))
    monkeypatch.setattr(service, "_application_running", lambda path: False)
    item = next(
        item
        for item in service.scan_applications().items
        if item.category_key == "maintenance.category.container"
    )

    def deny_trash(path: str) -> None:
        raise OSError("Insufficient access privileges for operation")

    monkeypatch.setattr("macscope.maintenance.send2trash", deny_trash)

    result = service.cleanup((item,))

    assert result.errors[0].code is CleanupFailureCode.PRIVACY_ACCESS


def test_unrelated_trash_error_remains_generic(tmp_path, monkeypatch) -> None:
    downloads = tmp_path / "Downloads"
    path = downloads / "large.bin"
    write_bytes(path, 1024)
    service = MaintenanceService(home=tmp_path, scan_roots=(downloads,))
    item = service.scan_large_files(0).items[0]

    def fail_trash(selected: str) -> None:
        raise OSError("volume is busy")

    monkeypatch.setattr("macscope.maintenance.send2trash", fail_trash)

    result = service.cleanup((item,))

    assert result.errors[0].code is CleanupFailureCode.TRASH_FAILED


def test_application_failure_prevents_related_data_cleanup(tmp_path, monkeypatch) -> None:
    applications = tmp_path / "Applications"
    app = applications / "Example.app"
    info = app / "Contents/Info.plist"
    info.parent.mkdir(parents=True)
    with info.open("wb") as handle:
        plistlib.dump({"CFBundleIdentifier": "com.example.Example"}, handle)
    cache = tmp_path / "Library/Caches/com.example.Example"
    write_bytes(cache / "data", 32)
    service = MaintenanceService(home=tmp_path, application_roots=(applications,))
    monkeypatch.setattr(service, "_application_running", lambda path: False)
    scanned = service.scan_applications().items
    app_item = next(item for item in scanned if item.kind is MaintenanceKind.APPLICATION)
    related_item = next(item for item in scanned if item.kind is MaintenanceKind.RESIDUE)
    attempts: list[Path] = []

    def deny_application(path: str) -> None:
        attempted = Path(path)
        attempts.append(attempted)
        if attempted == app:
            raise PermissionError("operation not permitted")

    monkeypatch.setattr("macscope.maintenance.send2trash", deny_application)

    result = service.cleanup((related_item, app_item))
    failures = {failure.item.id: failure.code for failure in result.errors}

    assert attempts == [app]
    assert failures[app_item.id] is CleanupFailureCode.PERMISSION
    assert failures[related_item.id] is CleanupFailureCode.PARENT_FAILED


def test_duplicate_scan_hashes_content_and_groups_only_matches(tmp_path) -> None:
    downloads = tmp_path / "Downloads"
    first = downloads / "first.bin"
    second = downloads / "second.bin"
    different = downloads / "different.bin"
    write_bytes(first, 32, b"a")
    write_bytes(second, 32, b"a")
    write_bytes(different, 32, b"b")
    service = MaintenanceService(home=tmp_path, scan_roots=(downloads,))

    result = service.scan_duplicates(minimum_size=1)

    assert {item.path for item in result.items} == {first, second}
    assert len({item.group for item in result.items}) == 1
