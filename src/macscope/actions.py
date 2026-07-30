from __future__ import annotations

import signal

import psutil

from macscope.i18n import Localizer
from macscope.models import ActionResult, ProcessSample
from macscope.process_guard import protected_pids


class ProcessController:
    def __init__(self, localizer: Localizer | None = None) -> None:
        self.localizer = localizer or Localizer()

    def _verified_process(
        self, target: ProcessSample
    ) -> tuple[psutil.Process | None, ActionResult | None]:
        if target.pid in protected_pids():
            return None, ActionResult(False, self.localizer("controller.self_signal"))
        try:
            process = psutil.Process(target.pid)
            if abs(process.create_time() - target.create_time) > 0.01:
                return None, ActionResult(False, self.localizer("controller.pid_reused"))
            return process, None
        except psutil.NoSuchProcess:
            return None, ActionResult(False, self.localizer("controller.exited"))
        except psutil.AccessDenied:
            return None, ActionResult(False, self.localizer("controller.permission"))

    def terminate(self, target: ProcessSample, *, force: bool = False) -> ActionResult:
        process, error = self._verified_process(target)
        if error is not None or process is None:
            return error or ActionResult(False, self.localizer("controller.unavailable"))
        try:
            if force:
                process.kill()
                return ActionResult(
                    True,
                    self.localizer(
                        "controller.signal_sent",
                        signal="SIGKILL",
                        name=target.name,
                        pid=target.pid,
                    ),
                )
            process.terminate()
            return ActionResult(
                True,
                self.localizer(
                    "controller.signal_sent",
                    signal="SIGTERM",
                    name=target.name,
                    pid=target.pid,
                ),
            )
        except psutil.AccessDenied:
            return ActionResult(False, self.localizer("controller.permission"))
        except psutil.NoSuchProcess:
            return ActionResult(False, self.localizer("controller.signal_race"))
        except OSError as exc:
            return ActionResult(False, str(exc))

    def toggle_pause(self, target: ProcessSample) -> ActionResult:
        process, error = self._verified_process(target)
        if error is not None or process is None:
            return error or ActionResult(False, self.localizer("controller.unavailable"))
        resume = target.status == psutil.STATUS_STOPPED
        try:
            process.send_signal(signal.SIGCONT if resume else signal.SIGSTOP)
            key = "controller.resumed" if resume else "controller.paused"
            return ActionResult(True, self.localizer(key, name=target.name, pid=target.pid))
        except psutil.AccessDenied:
            return ActionResult(False, self.localizer("controller.permission"))
        except psutil.NoSuchProcess:
            return ActionResult(False, self.localizer("controller.signal_race"))
        except OSError as exc:
            return ActionResult(False, str(exc))

    def set_priority(self, target: ProcessSample, value: int) -> ActionResult:
        process, error = self._verified_process(target)
        if error is not None or process is None:
            return error or ActionResult(False, self.localizer("controller.unavailable"))
        if not -20 <= value <= 20:
            return ActionResult(False, self.localizer("controller.nice_range"))
        try:
            process.nice(value)
            return ActionResult(
                True,
                self.localizer(
                    "controller.nice_set", name=target.name, pid=target.pid, value=value
                ),
            )
        except psutil.AccessDenied:
            return ActionResult(False, self.localizer("controller.permission"))
        except psutil.NoSuchProcess:
            return ActionResult(False, self.localizer("controller.priority_race"))
        except OSError as exc:
            return ActionResult(False, str(exc))
