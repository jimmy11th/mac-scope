from __future__ import annotations

import errno
import hashlib
import os
import plistlib
import shutil
import subprocess
import threading
from collections import defaultdict
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path

import psutil
from send2trash import send2trash


class MaintenanceKind(StrEnum):
    CACHE = "cache"
    LOG = "log"
    DIAGNOSTIC = "diagnostic"
    DEVELOPER = "developer"
    APPLICATION = "application"
    RESIDUE = "residue"
    LARGE_FILE = "large_file"
    DUPLICATE = "duplicate"


class CleanupFailureCode(StrEnum):
    NOT_FOUND = "not_found"
    CHANGED = "changed"
    OUTSIDE_SCOPE = "outside_scope"
    RUNNING = "running"
    PARENT_FAILED = "parent_failed"
    ADMIN_REQUIRED = "admin_required"
    PRIVACY_ACCESS = "privacy_access"
    PERMISSION = "permission"
    TRASH_FAILED = "trash_failed"


@dataclass(frozen=True, slots=True)
class FileIdentity:
    device: int
    inode: int
    size: int
    modified_ns: int


@dataclass(frozen=True, slots=True)
class MaintenanceItem:
    id: str
    kind: MaintenanceKind
    category_key: str
    name: str
    path: Path
    size: int
    modified: float
    identity: FileIdentity
    group: str = ""
    blocked_reason: str = ""
    parent_id: str = ""


@dataclass(frozen=True, slots=True)
class ScanResult:
    items: tuple[MaintenanceItem, ...]
    errors: tuple[str, ...] = ()
    scanned_files: int = 0

    @property
    def total_size(self) -> int:
        return sum(item.size for item in self.items)


@dataclass(frozen=True, slots=True)
class CleanupResult:
    deleted: tuple[MaintenanceItem, ...]
    trashed: tuple[MaintenanceItem, ...]
    errors: tuple[CleanupFailure, ...]

    @property
    def reclaimed_bytes(self) -> int:
        return sum(item.size for item in self.deleted)

    @property
    def trashed_bytes(self) -> int:
        return sum(item.size for item in self.trashed)


@dataclass(frozen=True, slots=True)
class CleanupFailure:
    item: MaintenanceItem
    code: CleanupFailureCode
    detail: str = ""


class CleanupValidationError(Exception):
    def __init__(self, code: CleanupFailureCode, message: str) -> None:
        super().__init__(message)
        self.code = code


ProgressCallback = Callable[[int, str], None]

PACKAGE_SUFFIXES = {
    ".app",
    ".bundle",
    ".framework",
    ".musiclibrary",
    ".photolibrary",
    ".photoslibrary",
}
PERMANENT_CACHE_KINDS = {
    MaintenanceKind.CACHE,
    MaintenanceKind.DEVELOPER,
}


class MaintenanceService:
    def __init__(
        self,
        *,
        home: Path | None = None,
        application_roots: Iterable[Path] | None = None,
        scan_roots: Iterable[Path] | None = None,
    ) -> None:
        self.home = (home or Path.home()).expanduser().absolute()
        self.application_roots = tuple(
            path.expanduser().absolute()
            for path in (application_roots or (Path("/Applications"), self.home / "Applications"))
        )
        self.scan_roots = tuple(
            path.expanduser().absolute()
            for path in (
                scan_roots
                or (
                    self.home / "Downloads",
                    self.home / "Desktop",
                    self.home / "Documents",
                    self.home / "Movies",
                )
            )
        )

    def set_scan_roots(self, scan_roots: Iterable[Path]) -> None:
        self.scan_roots = tuple(path.expanduser().absolute() for path in scan_roots)

    def scan_junk(
        self,
        cancel: threading.Event | None = None,
        progress: ProgressCallback | None = None,
    ) -> ScanResult:
        definitions = (
            (self.home / "Library/Caches", MaintenanceKind.CACHE, "maintenance.category.cache"),
            (self.home / "Library/Logs", MaintenanceKind.LOG, "maintenance.category.log"),
            (
                self.home / "Library/DiagnosticReports",
                MaintenanceKind.DIAGNOSTIC,
                "maintenance.category.diagnostic",
            ),
            (
                self.home / "Library/Developer/Xcode/DerivedData",
                MaintenanceKind.DEVELOPER,
                "maintenance.category.developer",
            ),
            (
                self.home / "Library/Developer/CoreSimulator/Caches",
                MaintenanceKind.DEVELOPER,
                "maintenance.category.developer",
            ),
        )
        items: list[MaintenanceItem] = []
        errors: list[str] = []
        scanned = 0
        for root, kind, category_key in definitions:
            if self._cancelled(cancel) or not root.is_dir():
                continue
            try:
                children = sorted(root.iterdir(), key=lambda path: path.name.casefold())
            except OSError as exc:
                errors.append(f"{root}: {exc}")
                continue
            for path in children:
                if self._cancelled(cancel):
                    return ScanResult(tuple(items), tuple(errors), scanned)
                try:
                    size, count = self._path_size(path, cancel)
                    identity = self._identity(path)
                    scanned += count
                    self._report(progress, scanned, path)
                    items.append(self._item(path, kind, category_key, size, identity=identity))
                except OSError as exc:
                    errors.append(f"{path}: {exc}")
        items.sort(key=lambda item: item.size, reverse=True)
        return ScanResult(tuple(items), tuple(errors), scanned)

    def scan_applications(
        self,
        cancel: threading.Event | None = None,
        progress: ProgressCallback | None = None,
    ) -> ScanResult:
        items: list[MaintenanceItem] = []
        errors: list[str] = []
        scanned = 0
        for app_path in self._application_paths(cancel):
            if self._cancelled(cancel):
                break
            try:
                metadata = self._application_metadata(app_path)
                bundle_id = metadata[0]
                name = metadata[1]
                size, count = self._path_size(app_path, cancel)
                scanned += count
                self._report(progress, scanned, app_path)
                blocked = "maintenance.running" if self._application_running(app_path) else ""
                app_item = self._item(
                    app_path,
                    MaintenanceKind.APPLICATION,
                    "maintenance.category.application",
                    size,
                    identity=self._identity(app_path),
                    name=name,
                    group=bundle_id,
                    blocked_reason=blocked,
                )
                items.append(app_item)
                if bundle_id:
                    for residue, category_key in self._residue_paths(bundle_id):
                        if self._cancelled(cancel) or not os.path.lexists(residue):
                            continue
                        try:
                            residue_size, count = self._path_size(residue, cancel)
                            scanned += count
                            items.append(
                                self._item(
                                    residue,
                                    MaintenanceKind.RESIDUE,
                                    category_key,
                                    residue_size,
                                    identity=self._identity(residue),
                                    group=bundle_id,
                                    parent_id=app_item.id,
                                )
                            )
                        except OSError as exc:
                            errors.append(f"{residue}: {exc}")
            except (OSError, ValueError, plistlib.InvalidFileException) as exc:
                errors.append(f"{app_path}: {exc}")
        items.sort(
            key=lambda item: (
                item.group.casefold(),
                item.kind is not MaintenanceKind.APPLICATION,
                -item.size,
            )
        )
        return ScanResult(tuple(items), tuple(errors), scanned)

    def scan_large_files(
        self,
        threshold_mb: int,
        cancel: threading.Event | None = None,
        progress: ProgressCallback | None = None,
    ) -> ScanResult:
        threshold = threshold_mb * 1024 * 1024
        items: list[MaintenanceItem] = []
        errors: list[str] = []
        scanned = 0
        for path, stat in self._iter_scan_files(cancel, errors):
            scanned += 1
            if scanned % 100 == 0:
                self._report(progress, scanned, path)
            if stat.st_size < threshold:
                continue
            items.append(
                self._item(
                    path,
                    MaintenanceKind.LARGE_FILE,
                    "maintenance.category.large",
                    stat.st_size,
                    identity=self._identity_from_stat(stat),
                )
            )
        items.sort(key=lambda item: item.size, reverse=True)
        return ScanResult(tuple(items), tuple(errors), scanned)

    def scan_duplicates(
        self,
        *,
        minimum_size: int = 10 * 1024 * 1024,
        cancel: threading.Event | None = None,
        progress: ProgressCallback | None = None,
    ) -> ScanResult:
        errors: list[str] = []
        by_size: dict[int, list[tuple[Path, os.stat_result]]] = defaultdict(list)
        scanned = 0
        seen_identities: set[tuple[int, int]] = set()
        for path, stat in self._iter_scan_files(cancel, errors):
            scanned += 1
            identity = (stat.st_dev, stat.st_ino)
            if stat.st_size >= minimum_size and identity not in seen_identities:
                by_size[stat.st_size].append((path, stat))
                seen_identities.add(identity)
            if scanned % 100 == 0:
                self._report(progress, scanned, path)

        items: list[MaintenanceItem] = []
        for size, candidates in by_size.items():
            if self._cancelled(cancel):
                break
            if len(candidates) < 2:
                continue
            by_hash: dict[str, list[tuple[Path, os.stat_result]]] = defaultdict(list)
            for path, stat in candidates:
                if self._cancelled(cancel):
                    break
                try:
                    digest = self._hash_file(path, cancel)
                    by_hash[digest].append((path, stat))
                except OSError as exc:
                    errors.append(f"{path}: {exc}")
            for digest, duplicates in by_hash.items():
                if len(duplicates) < 2:
                    continue
                group = digest[:10]
                for path, stat in sorted(duplicates, key=lambda entry: str(entry[0])):
                    items.append(
                        self._item(
                            path,
                            MaintenanceKind.DUPLICATE,
                            "maintenance.category.duplicate",
                            size,
                            identity=self._identity_from_stat(stat),
                            group=group,
                        )
                    )
        items.sort(key=lambda item: (-item.size, item.group, str(item.path)))
        return ScanResult(tuple(items), tuple(errors), scanned)

    def cleanup(
        self,
        items: Iterable[MaintenanceItem],
        *,
        cache_mode: str = "trash",
    ) -> CleanupResult:
        deleted: list[MaintenanceItem] = []
        trashed: list[MaintenanceItem] = []
        failures: list[CleanupFailure] = []
        candidates: list[MaintenanceItem] = []
        selected = list(items)
        failed_parents: set[str] = set()
        for item in selected:
            try:
                self._validate_cleanup_item(item)
                if item.kind is MaintenanceKind.APPLICATION and self._application_running(
                    item.path
                ):
                    raise CleanupValidationError(
                        CleanupFailureCode.RUNNING,
                        "application is running",
                    )
                candidates.append(item)
            except CleanupValidationError as exc:
                failures.append(CleanupFailure(item, exc.code, str(exc)))
                if item.kind is MaintenanceKind.APPLICATION:
                    failed_parents.add(item.id)
            except OSError as exc:
                failure = self._classify_os_error(item, exc)
                failures.append(failure)
                if item.kind is MaintenanceKind.APPLICATION:
                    failed_parents.add(item.id)

        candidates.sort(key=lambda item: item.kind is not MaintenanceKind.APPLICATION)
        for item in candidates:
            if item.parent_id and item.parent_id in failed_parents:
                failures.append(
                    CleanupFailure(
                        item,
                        CleanupFailureCode.PARENT_FAILED,
                        "application was not uninstalled",
                    )
                )
                continue
            try:
                permanent = cache_mode == "delete" and item.kind in PERMANENT_CACHE_KINDS
                if permanent:
                    self._delete_path(item.path)
                    deleted.append(item)
                else:
                    send2trash(str(item.path))
                    trashed.append(item)
            except OSError as exc:
                failure = self._classify_os_error(item, exc)
                failures.append(failure)
                if item.kind is MaintenanceKind.APPLICATION:
                    failed_parents.add(item.id)
        return CleanupResult(tuple(deleted), tuple(trashed), tuple(failures))

    @staticmethod
    def release_file_cache(timeout: float = 20.0) -> tuple[bool, str]:
        purge = Path("/usr/bin/purge")
        if not purge.exists():
            return False, "purge is unavailable on this version of macOS"
        try:
            result = subprocess.run(
                [str(purge)],
                capture_output=True,
                text=True,
                timeout=timeout,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            return False, str(exc)
        message = (result.stderr or result.stdout).strip()
        return result.returncode == 0, message

    def _validate_cleanup_item(self, item: MaintenanceItem) -> None:
        path = item.path.expanduser().absolute()
        if not os.path.lexists(path):
            raise CleanupValidationError(
                CleanupFailureCode.NOT_FOUND,
                "item no longer exists",
            )
        if item.kind is MaintenanceKind.APPLICATION:
            allowed = any(
                path.is_relative_to(root) and path != root for root in self.application_roots
            )
        elif item.kind in {MaintenanceKind.LARGE_FILE, MaintenanceKind.DUPLICATE}:
            allowed = any(path.is_relative_to(root) and path != root for root in self.scan_roots)
        else:
            allowed = path.is_relative_to(self.home) and path != self.home
        if not allowed or path.is_relative_to(Path("/System")):
            raise CleanupValidationError(
                CleanupFailureCode.OUTSIDE_SCOPE,
                "path is outside the allowed cleanup roots",
            )
        if self._identity(path) != item.identity:
            raise CleanupValidationError(
                CleanupFailureCode.CHANGED,
                "item changed after scanning",
            )

    def _classify_os_error(
        self,
        item: MaintenanceItem,
        error: OSError,
    ) -> CleanupFailure:
        message = str(error).casefold()
        permission_denied = (
            isinstance(error, PermissionError)
            or error.errno in {errno.EACCES, errno.EPERM}
            or any(
                marker in message
                for marker in (
                    "insufficient access privileges",
                    "operation not permitted",
                    "permission denied",
                    "not authorized",
                    "don't have permission",
                    "don’t have permission",
                )
            )
        )
        if isinstance(error, FileNotFoundError):
            code = CleanupFailureCode.NOT_FOUND
        elif permission_denied:
            if item.category_key == "maintenance.category.container":
                code = CleanupFailureCode.PRIVACY_ACCESS
            elif item.kind is MaintenanceKind.APPLICATION and item.path.is_relative_to(
                Path("/Applications")
            ):
                code = CleanupFailureCode.ADMIN_REQUIRED
            else:
                code = CleanupFailureCode.PERMISSION
        else:
            code = CleanupFailureCode.TRASH_FAILED
        return CleanupFailure(item, code, str(error))

    @staticmethod
    def _delete_path(path: Path) -> None:
        if path.is_symlink() or not path.is_dir():
            path.unlink()
        else:
            shutil.rmtree(path)

    def _application_paths(self, cancel: threading.Event | None) -> tuple[Path, ...]:
        paths: list[Path] = []
        for root in self.application_roots:
            if not root.is_dir():
                continue
            try:
                for current, directories, _ in os.walk(root):
                    if self._cancelled(cancel):
                        return tuple(paths)
                    relative_depth = len(Path(current).relative_to(root).parts)
                    if relative_depth > 2:
                        directories[:] = []
                        continue
                    app_directories = [name for name in directories if name.endswith(".app")]
                    paths.extend(Path(current) / name for name in app_directories)
                    directories[:] = [
                        name
                        for name in directories
                        if not name.endswith(".app") and not name.startswith(".")
                    ]
            except OSError:
                continue
        return tuple(sorted(set(paths), key=lambda path: path.name.casefold()))

    @staticmethod
    def _application_metadata(path: Path) -> tuple[str, str]:
        info_path = path / "Contents/Info.plist"
        bundle_id = ""
        name = path.stem
        try:
            with info_path.open("rb") as handle:
                info = plistlib.load(handle)
            if isinstance(info, dict):
                identifier = info.get("CFBundleIdentifier", "")
                display_name = info.get("CFBundleDisplayName") or info.get("CFBundleName")
                bundle_id = identifier if isinstance(identifier, str) else ""
                name = display_name if isinstance(display_name, str) and display_name else name
        except FileNotFoundError:
            pass
        return bundle_id, name

    def _residue_paths(self, bundle_id: str) -> tuple[tuple[Path, str], ...]:
        library = self.home / "Library"
        return (
            (
                library / "Caches" / bundle_id,
                "maintenance.category.app_cache",
            ),
            (
                library / "Preferences" / f"{bundle_id}.plist",
                "maintenance.category.preference",
            ),
            (
                library / "Saved Application State" / f"{bundle_id}.savedState",
                "maintenance.category.saved_state",
            ),
            (
                library / "Application Support" / bundle_id,
                "maintenance.category.app_support",
            ),
            (
                library / "Containers" / bundle_id,
                "maintenance.category.container",
            ),
        )

    @staticmethod
    def _application_running(path: Path) -> bool:
        app = path.absolute()
        for process in psutil.process_iter(["exe"], ad_value=None):
            try:
                executable = process.info.get("exe")
                if executable and Path(executable).absolute().is_relative_to(app):
                    return True
            except (OSError, psutil.Error, ValueError):
                continue
        return False

    def _iter_scan_files(
        self,
        cancel: threading.Event | None,
        errors: list[str],
    ):
        for root in self.scan_roots:
            if not root.is_dir():
                continue
            stack = [root]
            while stack and not self._cancelled(cancel):
                directory = stack.pop()
                try:
                    with os.scandir(directory) as entries:
                        for entry in entries:
                            if self._cancelled(cancel):
                                return
                            try:
                                if entry.is_symlink():
                                    continue
                                path = Path(entry.path)
                                if entry.is_dir(follow_symlinks=False):
                                    if (
                                        entry.name.startswith(".")
                                        or path.suffix.lower() in PACKAGE_SUFFIXES
                                    ):
                                        continue
                                    stack.append(path)
                                elif entry.is_file(follow_symlinks=False):
                                    yield path, entry.stat(follow_symlinks=False)
                            except OSError as exc:
                                errors.append(f"{entry.path}: {exc}")
                except OSError as exc:
                    errors.append(f"{directory}: {exc}")

    @staticmethod
    def _path_size(path: Path, cancel: threading.Event | None) -> tuple[int, int]:
        stat = path.lstat()
        if path.is_symlink() or not path.is_dir():
            return stat.st_size, 1
        total = 0
        count = 0
        stack = [path]
        while stack and not MaintenanceService._cancelled(cancel):
            directory = stack.pop()
            try:
                with os.scandir(directory) as entries:
                    for entry in entries:
                        try:
                            stat = entry.stat(follow_symlinks=False)
                            total += stat.st_size
                            count += 1
                            if entry.is_dir(follow_symlinks=False) and not entry.is_symlink():
                                stack.append(Path(entry.path))
                        except OSError:
                            continue
            except OSError:
                continue
        return total, max(1, count)

    @staticmethod
    def _hash_file(path: Path, cancel: threading.Event | None) -> str:
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            while not MaintenanceService._cancelled(cancel):
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    return digest.hexdigest()
                digest.update(chunk)
        return ""

    @staticmethod
    def _identity(path: Path) -> FileIdentity:
        return MaintenanceService._identity_from_stat(path.lstat())

    @staticmethod
    def _identity_from_stat(stat: os.stat_result) -> FileIdentity:
        return FileIdentity(stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns)

    @staticmethod
    def _item(
        path: Path,
        kind: MaintenanceKind,
        category_key: str,
        size: int,
        *,
        identity: FileIdentity,
        name: str = "",
        group: str = "",
        blocked_reason: str = "",
        parent_id: str = "",
    ) -> MaintenanceItem:
        identifier = hashlib.blake2s(str(path).encode(), digest_size=12).hexdigest()
        return MaintenanceItem(
            identifier,
            kind,
            category_key,
            name or path.name,
            path,
            size,
            identity.modified_ns / 1_000_000_000,
            identity,
            group,
            blocked_reason,
            parent_id,
        )

    @staticmethod
    def _cancelled(cancel: threading.Event | None) -> bool:
        return cancel is not None and cancel.is_set()

    @staticmethod
    def _report(progress: ProgressCallback | None, count: int, path: Path) -> None:
        if progress is not None:
            progress(count, str(path))
