from __future__ import annotations

import plistlib

from macscope.settings import Settings, SettingsStore, resolve_scan_roots


def test_settings_round_trip(tmp_path) -> None:
    store = SettingsStore(tmp_path / "settings.plist")
    settings = Settings(
        language="zh-CN",
        theme="nord",
        refresh_interval=2.0,
        default_top_rows=9,
        temperature_unit="fahrenheit",
        smoothing_seconds=5.0,
        network_interface="en7",
        show_self=False,
        include_inactive_io=True,
        cache_cleanup_mode="delete",
        large_file_threshold_mb=1024,
        duplicate_minimum_size_mb=100,
        default_sort_key="memory",
        default_sort_descending=False,
        maintenance_scan_roots=("~/Downloads", "/Volumes/Work"),
    )

    store.save(settings)

    assert store.load() == settings
    assert store.warning == ""


def test_invalid_settings_are_repaired_field_by_field(tmp_path) -> None:
    path = tmp_path / "settings.plist"
    with path.open("wb") as handle:
        plistlib.dump(
            {
                "language": "unknown",
                "theme": "nord",
                "refresh_interval": 17,
                "default_top_rows": 999,
                "temperature_unit": "kelvin",
                "smoothing_seconds": "fast",
                "network_interface": [],
                "show_self": "yes",
                "include_inactive_io": True,
                "cache_cleanup_mode": "erase-everything",
                "large_file_threshold_mb": 42,
                "duplicate_minimum_size_mb": 42,
                "default_sort_key": "temperature",
                "default_sort_descending": "yes",
                "maintenance_scan_roots": [],
            },
            handle,
        )

    settings = SettingsStore(path).load()

    assert settings.language == "en"
    assert settings.theme == "nord"
    assert settings.refresh_interval == 1.0
    assert settings.default_top_rows == 20
    assert settings.temperature_unit == "celsius"
    assert settings.smoothing_seconds == 3.0
    assert settings.network_interface == "auto"
    assert settings.show_self is True
    assert settings.include_inactive_io is True
    assert settings.cache_cleanup_mode == "trash"
    assert settings.large_file_threshold_mb == 500
    assert settings.duplicate_minimum_size_mb == 10
    assert settings.default_sort_key == "cpu"
    assert settings.default_sort_descending is True
    assert settings.maintenance_scan_roots == Settings().maintenance_scan_roots


def test_corrupt_settings_fall_back_with_warning(tmp_path) -> None:
    path = tmp_path / "settings.plist"
    path.write_bytes(b"not a plist")
    store = SettingsStore(path)

    assert store.load() == Settings()
    assert store.warning.startswith("Invalid settings file:")


def test_scan_roots_resolve_user_paths_and_reject_system_root(tmp_path) -> None:
    settings = Settings(
        maintenance_scan_roots=("~/Downloads", "Projects", "/System", "/"),
    )

    assert resolve_scan_roots(settings, home=tmp_path) == (
        tmp_path / "Downloads",
        tmp_path / "Projects",
    )
