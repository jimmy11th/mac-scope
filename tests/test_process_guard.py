from __future__ import annotations

import os

from macscope.process_guard import protected_pids


def test_protected_pids_include_current_process_and_valid_host() -> None:
    assert protected_pids({"MACSCOPE_HOST_PID": "4242"}) == frozenset({0, os.getpid(), 4242})


def test_protected_pids_ignore_invalid_hosts() -> None:
    expected = frozenset({0, os.getpid()})

    assert protected_pids({"MACSCOPE_HOST_PID": "not-a-pid"}) == expected
    assert protected_pids({"MACSCOPE_HOST_PID": "-1"}) == expected
