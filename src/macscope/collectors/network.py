from __future__ import annotations

import csv
import os
import pty
import subprocess
import threading
import time
from collections.abc import Sequence
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class NetworkProcessStats:
    pid: int
    name: str
    download_total: int
    upload_total: int
    download_rate: float
    upload_rate: float


def parse_nettop_row(row: Sequence[str]) -> tuple[int, str, int, int] | None:
    if len(row) < 3 or not row[0] or "." not in row[0]:
        return None
    identity = row[0]
    name, pid_text = identity.rsplit(".", 1)
    try:
        pid = int(pid_text)
        downloaded = int(row[1] or 0)
        uploaded = int(row[2] or 0)
    except ValueError:
        return None
    return pid, name.strip() or f"PID {pid}", downloaded, uploaded


class NetTopSampler:
    """Continuously reads per-process external traffic from macOS nettop."""

    def __init__(self, interval: float = 1.0) -> None:
        self.interval = interval
        self._lock = threading.Lock()
        self._latest: dict[int, NetworkProcessStats] = {}
        self._previous: dict[int, tuple[str, int, int]] = {}
        self._current: dict[int, tuple[str, int, int]] = {}
        self._last_commit: float | None = None
        self._process: subprocess.Popen[str] | None = None
        self._stream = None
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self.error: str = ""

    def start(self) -> None:
        if self._process is not None:
            return
        master_fd, slave_fd = pty.openpty()
        try:
            self._process = subprocess.Popen(
                [
                    "/usr/bin/nettop",
                    "-P",
                    "-L",
                    "0",
                    "-x",
                    "-n",
                    "-t",
                    "external",
                    "-s",
                    str(self.interval),
                    "-J",
                    "bytes_in,bytes_out",
                ],
                stdout=slave_fd,
                stderr=subprocess.DEVNULL,
                close_fds=True,
            )
        except OSError as exc:
            os.close(master_fd)
            os.close(slave_fd)
            self.error = f"nettop unavailable: {exc}"
            return
        os.close(slave_fd)
        self._stream = os.fdopen(master_fd, "r", encoding="utf-8", errors="replace", buffering=1)
        self._stop.clear()
        self._thread = threading.Thread(target=self._read_loop, name="nettop-reader", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        process = self._process
        self._process = None
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=1)
        if self._thread is not None:
            self._thread.join(timeout=1)
            self._thread = None
        if self._stream is not None:
            self._stream.close()
            self._stream = None

    def snapshot(self) -> dict[int, NetworkProcessStats]:
        with self._lock:
            return dict(self._latest)

    def set_interval(self, interval: float) -> None:
        if abs(self.interval - interval) < 0.001:
            return
        running = self._process is not None
        if running:
            self.stop()
        self.interval = interval
        with self._lock:
            self._latest = {}
        self._previous = {}
        self._current = {}
        self._last_commit = None
        self.error = ""
        if running:
            self.start()

    def _read_loop(self) -> None:
        process = self._process
        stream = self._stream
        if process is None or stream is None:
            return
        try:
            for line in stream:
                if self._stop.is_set():
                    break
                row = next(csv.reader([line]))
                if row and (row[0] == "" or row[0] == "time"):
                    self._commit()
                    continue
                parsed = parse_nettop_row(row)
                if parsed is not None:
                    pid, name, downloaded, uploaded = parsed
                    self._current[pid] = (name, downloaded, uploaded)
        except (OSError, csv.Error) as exc:
            if not self._stop.is_set():
                self.error = f"nettop reader stopped: {exc}"
        finally:
            self._commit()
            if not self._stop.is_set() and not self.error:
                self.error = "nettop stopped unexpectedly; process network rates are stale."

    def _commit(self) -> None:
        if not self._current:
            return
        now = time.monotonic()
        elapsed = now - self._last_commit if self._last_commit is not None else 0.0
        latest: dict[int, NetworkProcessStats] = {}
        for pid, (name, downloaded, uploaded) in self._current.items():
            previous = self._previous.get(pid)
            download_rate = 0.0
            upload_rate = 0.0
            if previous is not None and elapsed > 0:
                _, old_downloaded, old_uploaded = previous
                download_rate = max(0, downloaded - old_downloaded) / elapsed
                upload_rate = max(0, uploaded - old_uploaded) / elapsed
            latest[pid] = NetworkProcessStats(
                pid=pid,
                name=name,
                download_total=downloaded,
                upload_total=uploaded,
                download_rate=download_rate,
                upload_rate=upload_rate,
            )
        with self._lock:
            self._latest = latest
        self._previous = self._current
        self._current = {}
        self._last_commit = now
