#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

# Without a controlling terminal, init must fail without retaining an identity.
python3 - <<'PY'
import os
import pathlib
import subprocess

data = pathlib.Path(os.environ["XDG_DATA_HOME"]) / "envy"
result = subprocess.run(
    [os.environ["ENVY_BIN"], "init", os.environ["TEST_REMOTE"]],
    stdin=subprocess.DEVNULL, capture_output=True, start_new_session=True,
)
assert result.returncode != 0
assert b"could not protect identity" in result.stderr
assert not list(data.iterdir()), "failed init left local files"
PY

python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-cleanup-passphrase
throwaway-cleanup-passphrase
RESPONSES

# Observe terminal state and local files through real interrupted CLI commands.
python3 - <<'PY'
import os
import pathlib
import pty
import select
import signal
import subprocess
import termios
import time

tool = os.environ["ENVY_BIN"]
data = pathlib.Path(os.environ["XDG_DATA_HOME"]) / "envy"
before = sorted(data.iterdir())
revision = subprocess.check_output(
    ["git", "--git-dir=" + os.environ["TEST_REMOTE"], "rev-parse", "HEAD"]
)

for disconnect in (False, True):
    pid, terminal = pty.fork()
    if pid == 0:
        os.execv(tool, [tool, "set", "INTERRUPTED"])
    reaped = False
    try:
        output = b""
        deadline = time.monotonic() + 10
        while b"Secret value: " not in output:
            assert time.monotonic() < deadline, "set did not prompt"
            if select.select([terminal], [], [], 0.1)[0]:
                output += os.read(terminal, 4096)
        assert not termios.tcgetattr(terminal)[3] & termios.ECHO
        if disconnect:
            os.close(terminal)
            terminal = None
        else:
            os.kill(pid, signal.SIGTERM)
        while True:
            ended, status = os.waitpid(pid, os.WNOHANG)
            if ended:
                reaped = True
                break
            assert time.monotonic() < deadline, "interrupted set did not exit"
            time.sleep(0.01)
        assert not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0
        if not disconnect:
            assert termios.tcgetattr(terminal)[3] & termios.ECHO, "echo not restored"
        assert sorted(data.iterdir()) == before, "interrupted set left local files"
    finally:
        if not reaped:
            os.killpg(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        if terminal is not None:
            os.close(terminal)

assert subprocess.check_output([tool, "ls"]) == b""
assert subprocess.check_output(
    ["git", "--git-dir=" + os.environ["TEST_REMOTE"], "rev-parse", "HEAD"]
) == revision, "interrupted set pushed a write"
assert subprocess.check_output(["git", "-C", str(data / "store"), "status", "--porcelain"]) == b""
PY
