from __future__ import annotations

import subprocess
import time
from dataclasses import replace

import psutil
from conftest import make_process

from macscope.actions import ProcessController


def sample_for(process: psutil.Process):
    return make_process(
        pid=process.pid,
        create_time=process.create_time(),
        name=process.name(),
        status=process.status(),
    )


def wait_for_status(process: psutil.Process, status: str, timeout: float = 2.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.status() == status:
            return
        time.sleep(0.02)
    raise AssertionError(f"PID {process.pid} did not reach {status}")


def wait_until_resumed(process: psutil.Process, timeout: float = 2.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.status() != psutil.STATUS_STOPPED:
            return
        time.sleep(0.02)
    raise AssertionError(f"PID {process.pid} did not resume")


def test_pid_reuse_guard_refuses_mismatched_identity() -> None:
    child = subprocess.Popen(["/bin/sleep", "30"])
    process = psutil.Process(child.pid)
    controller = ProcessController()
    try:
        target = replace(sample_for(process), create_time=process.create_time() + 10)
        result = controller.terminate(target)
        assert not result.ok
        assert "another process" in result.message
        assert child.poll() is None
    finally:
        child.kill()
        child.wait(timeout=2)


def test_native_host_process_is_protected(monkeypatch) -> None:
    child = subprocess.Popen(["/bin/sleep", "30"])
    process = psutil.Process(child.pid)
    monkeypatch.setenv("MACSCOPE_HOST_PID", str(child.pid))
    try:
        result = ProcessController().terminate(sample_for(process))
        assert not result.ok
        assert "will not signal" in result.message
        assert child.poll() is None
    finally:
        child.kill()
        child.wait(timeout=2)


def test_pause_resume_priority_and_terminate_child() -> None:
    child = subprocess.Popen(["/bin/sleep", "30"])
    process = psutil.Process(child.pid)
    controller = ProcessController()
    try:
        target = sample_for(process)
        paused = controller.toggle_pause(target)
        assert paused.ok
        wait_for_status(process, psutil.STATUS_STOPPED)

        resumed = controller.toggle_pause(replace(target, status=psutil.STATUS_STOPPED))
        assert resumed.ok
        wait_until_resumed(process)

        priority = controller.set_priority(target, 10)
        assert priority.ok
        assert process.nice() == 10

        terminated = controller.terminate(target)
        assert terminated.ok
        child.wait(timeout=2)
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=2)


def test_force_kill_child() -> None:
    child = subprocess.Popen(["/bin/sleep", "30"])
    process = psutil.Process(child.pid)
    try:
        result = ProcessController().terminate(sample_for(process), force=True)
        assert result.ok
        child.wait(timeout=2)
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=2)
