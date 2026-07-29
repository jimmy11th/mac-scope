from __future__ import annotations

import time

from macscope.models import ProcessSample


def make_process(**overrides) -> ProcessSample:
    values = {
        "pid": 123,
        "create_time": time.time() - 60,
        "name": "example",
        "username": "tester",
        "command": "/usr/bin/example --serve",
        "status": "running",
        "cpu_percent": 12.0,
        "cpu_score": 10.0,
        "memory_rss": 256 * 1024 * 1024,
        "memory_percent": 1.5,
        "memory_growth": 1024.0,
        "threads": 4,
        "elapsed": 60.0,
        "disk_read_rate": 2000.0,
        "disk_write_rate": 3000.0,
        "disk_read_total": 100_000,
        "disk_write_total": 200_000,
        "disk_score": 5000.0,
        "network_download_rate": 6000.0,
        "network_upload_rate": 4000.0,
        "network_download_total": 300_000,
        "network_upload_total": 100_000,
        "network_score": 10_000.0,
        "connections": 2,
    }
    values.update(overrides)
    return ProcessSample(**values)
