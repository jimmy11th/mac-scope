from __future__ import annotations

import os
import plistlib
import tempfile
from dataclasses import asdict, dataclass, replace
from pathlib import Path
from typing import Any

LANGUAGES = ("en", "zh-CN")
REFRESH_INTERVALS = (0.5, 1.0, 2.0, 5.0)
SMOOTHING_INTERVALS = (0.0, 3.0, 5.0)
TEMPERATURE_UNITS = ("celsius", "fahrenheit")
CACHE_CLEANUP_MODES = ("trash", "delete")
LARGE_FILE_THRESHOLDS_MB = (100, 500, 1024, 5120)
DUPLICATE_MINIMUM_SIZES_MB = (1, 10, 100, 500)
PROCESS_SORT_KEYS = (
    "process",
    "pid",
    "cpu",
    "memory",
    "disk_read",
    "disk_write",
    "network_down",
    "network_up",
    "threads",
    "runtime",
)
DEFAULT_MAINTENANCE_SCAN_ROOTS = (
    "~/Downloads",
    "~/Desktop",
    "~/Documents",
    "~/Movies",
)


def default_data_directory() -> Path:
    return Path.home() / "Library" / "Application Support" / "MacScope"


@dataclass(frozen=True, slots=True)
class Settings:
    schema_version: int = 3
    language: str = "en"
    theme: str = "graphite-dark"
    refresh_interval: float = 1.0
    default_top_rows: int = 5
    temperature_unit: str = "celsius"
    smoothing_seconds: float = 3.0
    network_interface: str = "auto"
    show_self: bool = True
    include_inactive_io: bool = False
    cache_cleanup_mode: str = "trash"
    large_file_threshold_mb: int = 500
    duplicate_minimum_size_mb: int = 10
    default_sort_key: str = "cpu"
    default_sort_descending: bool = True
    maintenance_scan_roots: tuple[str, ...] = DEFAULT_MAINTENANCE_SCAN_ROOTS

    def with_overrides(self, **values: Any) -> Settings:
        return validate_settings(replace(self, **values))


def validate_settings(settings: Settings) -> Settings:
    defaults = Settings()
    refresh_interval = (
        float(settings.refresh_interval)
        if isinstance(settings.refresh_interval, (int, float))
        and not isinstance(settings.refresh_interval, bool)
        and float(settings.refresh_interval) in REFRESH_INTERVALS
        else defaults.refresh_interval
    )
    smoothing_seconds = (
        float(settings.smoothing_seconds)
        if isinstance(settings.smoothing_seconds, (int, float))
        and not isinstance(settings.smoothing_seconds, bool)
        and float(settings.smoothing_seconds) in SMOOTHING_INTERVALS
        else defaults.smoothing_seconds
    )
    top_rows = (
        settings.default_top_rows
        if isinstance(settings.default_top_rows, int)
        and not isinstance(settings.default_top_rows, bool)
        else defaults.default_top_rows
    )
    large_file_threshold_mb = (
        settings.large_file_threshold_mb
        if isinstance(settings.large_file_threshold_mb, int)
        and not isinstance(settings.large_file_threshold_mb, bool)
        and settings.large_file_threshold_mb in LARGE_FILE_THRESHOLDS_MB
        else defaults.large_file_threshold_mb
    )
    duplicate_minimum_size_mb = (
        settings.duplicate_minimum_size_mb
        if isinstance(settings.duplicate_minimum_size_mb, int)
        and not isinstance(settings.duplicate_minimum_size_mb, bool)
        and settings.duplicate_minimum_size_mb in DUPLICATE_MINIMUM_SIZES_MB
        else defaults.duplicate_minimum_size_mb
    )
    scan_roots = (
        tuple(dict.fromkeys(value.strip() for value in settings.maintenance_scan_roots))
        if isinstance(settings.maintenance_scan_roots, (list, tuple))
        and settings.maintenance_scan_roots
        and all(
            isinstance(value, str) and value.strip() and "\x00" not in value
            for value in settings.maintenance_scan_roots
        )
        else defaults.maintenance_scan_roots
    )
    return Settings(
        schema_version=3,
        language=(
            settings.language
            if isinstance(settings.language, str) and settings.language in LANGUAGES
            else defaults.language
        ),
        theme=(
            settings.theme if isinstance(settings.theme, str) and settings.theme else defaults.theme
        ),
        refresh_interval=refresh_interval,
        default_top_rows=min(20, max(1, top_rows)),
        temperature_unit=(
            settings.temperature_unit
            if isinstance(settings.temperature_unit, str)
            and settings.temperature_unit in TEMPERATURE_UNITS
            else defaults.temperature_unit
        ),
        smoothing_seconds=smoothing_seconds,
        network_interface=(
            settings.network_interface
            if isinstance(settings.network_interface, str) and settings.network_interface
            else defaults.network_interface
        ),
        show_self=(
            settings.show_self if isinstance(settings.show_self, bool) else defaults.show_self
        ),
        include_inactive_io=(
            settings.include_inactive_io
            if isinstance(settings.include_inactive_io, bool)
            else defaults.include_inactive_io
        ),
        cache_cleanup_mode=(
            settings.cache_cleanup_mode
            if isinstance(settings.cache_cleanup_mode, str)
            and settings.cache_cleanup_mode in CACHE_CLEANUP_MODES
            else defaults.cache_cleanup_mode
        ),
        large_file_threshold_mb=large_file_threshold_mb,
        duplicate_minimum_size_mb=duplicate_minimum_size_mb,
        default_sort_key=(
            settings.default_sort_key
            if isinstance(settings.default_sort_key, str)
            and settings.default_sort_key in PROCESS_SORT_KEYS
            else defaults.default_sort_key
        ),
        default_sort_descending=(
            settings.default_sort_descending
            if isinstance(settings.default_sort_descending, bool)
            else defaults.default_sort_descending
        ),
        maintenance_scan_roots=scan_roots,
    )


def resolve_scan_roots(settings: Settings, home: Path | None = None) -> tuple[Path, ...]:
    home = (home or Path.home()).expanduser().absolute()
    roots: list[Path] = []
    for value in settings.maintenance_scan_roots:
        path = (
            home / value.removeprefix("~/") if value.startswith("~/") else Path(value).expanduser()
        )
        if not path.is_absolute():
            path = home / path
        path = path.absolute()
        if path == Path("/") or path.is_relative_to(Path("/System")):
            continue
        if path not in roots:
            roots.append(path)
    if roots:
        return tuple(roots)
    return tuple(
        (home / value.removeprefix("~/")).absolute() for value in DEFAULT_MAINTENANCE_SCAN_ROOTS
    )


class SettingsStore:
    def __init__(self, path: Path | None = None) -> None:
        self.path = path or default_data_directory() / "settings.plist"
        self.warning = ""

    @property
    def data_directory(self) -> Path:
        return self.path.parent

    def load(self) -> Settings:
        self.warning = ""
        if not self.path.exists():
            return Settings()
        try:
            with self.path.open("rb") as handle:
                data = plistlib.load(handle)
            if not isinstance(data, dict):
                raise TypeError("settings root must be a dictionary")
            defaults = asdict(Settings())
            values = {key: data.get(key, value) for key, value in defaults.items()}
            return validate_settings(Settings(**values))
        except (OSError, ValueError, TypeError, plistlib.InvalidFileException) as exc:
            self.warning = f"Invalid settings file: {exc}"
            return Settings()

    def save(self, settings: Settings) -> None:
        settings = validate_settings(settings)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary_name = tempfile.mkstemp(
            prefix="settings-", suffix=".plist", dir=self.path.parent
        )
        try:
            with os.fdopen(descriptor, "wb") as handle:
                plistlib.dump(asdict(settings), handle, fmt=plistlib.FMT_BINARY, sort_keys=True)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary_name, self.path)
        except Exception:
            try:
                os.unlink(temporary_name)
            except OSError:
                pass
            raise
