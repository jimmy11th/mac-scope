from __future__ import annotations

import os
from collections.abc import Mapping


def protected_pids(environment: Mapping[str, str] | None = None) -> frozenset[int]:
    """Return PIDs that MacScope must never manage as external processes."""
    source = os.environ if environment is None else environment
    pids = {0, os.getpid()}
    try:
        host_pid = int(source.get("MACSCOPE_HOST_PID", ""))
    except ValueError:
        host_pid = 0
    if host_pid > 0:
        pids.add(host_pid)
    return frozenset(pids)
