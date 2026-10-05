"""Controlling-terminal children for CLI tests, with bounded, private output."""

import errno
import os
import pty
import select
import signal
import subprocess
import termios
import time


def kill_process_group(pid):
    """Kill our child; tolerate a vanished group on both macOS and Linux."""
    try:
        os.killpg(pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        # macOS can report EPERM for a vanished group. Fall back to the child
        # itself, so an actual live-child permission error still gets reported.
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


class PtyProcess:
    """A pty.fork child, not a new session merely connected to a pty slave."""

    def __init__(self, command, env=None):
        self.command = command
        self.output = bytearray()
        self.returncode = None
        ready_read, ready_write = os.pipe()
        self.pid, self.terminal = pty.fork()
        if self.pid == 0:
            os.close(ready_write)
            # Let the parent snapshot terminal state before the CLI changes it.
            os.read(ready_read, 1)
            os.close(ready_read)
            try:
                os.execvpe(command[0], command, os.environ if env is None else env)
            except OSError:
                os._exit(127)
        os.close(ready_read)
        self.original_state = termios.tcgetattr(self.terminal)
        os.write(ready_write, b"1")
        os.close(ready_write)

    def poll(self):
        if self.returncode is None:
            ended, status = os.waitpid(self.pid, os.WNOHANG)
            if ended:
                self.returncode = os.waitstatus_to_exitcode(status)
        return self.returncode

    def drain(self, timeout=0):
        if select.select([self.terminal], [], [], timeout)[0]:
            try:
                data = os.read(self.terminal, 4096)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                data = b""
            self.output.extend(data)
            return bool(data)
        return False

    def expect(self, prompt, timeout=10):
        deadline = time.monotonic() + timeout
        while prompt not in self.output:
            assert self.poll() is None, "terminal command exited before prompting"
            assert time.monotonic() < deadline, "terminal command did not prompt"
            self.drain(0.05)

    def wait(self, timeout=10):
        deadline = time.monotonic() + timeout
        while self.poll() is None:
            if time.monotonic() >= deadline:
                raise subprocess.TimeoutExpired(self.command, timeout)
            # Drain throughout the wait, including after input has been sent.
            self.drain(0.05)
        while self.drain():
            pass
        return self.returncode

    def communicate(self, timeout=10):
        self.wait(timeout)
        return bytes(self.output), b""

    def close(self):
        os.close(self.terminal)
