#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-background-failures-passphrase
throwaway-background-failures-passphrase
RESPONSES

# Keep the SSH fixture passphrase in the terminal helper's input, never argv.
python3 "$TEST_ROOT/tests/pty-helper.py" -- ssh-keygen -q -t ed25519 -f "$HOME/ssh-key" <<'RESPONSES'
throwaway-ssh-passphrase
throwaway-ssh-passphrase
RESPONSES

python3 - <<'PY'
import os
import pathlib
import pty
import select
import signal
import subprocess
import time

home = pathlib.Path(os.environ["HOME"])
state = pathlib.Path(os.environ["XDG_STATE_HOME"]) / "envy"
store = pathlib.Path(os.environ["XDG_DATA_HOME"]) / "envy/store"
tool = os.environ["ENVY_BIN"]
bin_dir = home / "failure-bin"
bin_dir.mkdir()
environment = os.environ.copy()
environment["PATH"] = str(bin_dir) + ":" + environment["PATH"]
environment["REAL_DATE"] = subprocess.check_output(["sh", "-c", "command -v date"], text=True).strip()
environment["REAL_GIT"] = subprocess.check_output(["sh", "-c", "command -v git"], text=True).strip()

# Interrupt the second date invocation: pull first checks its lock timeout,
# then writes the successful-fetch timestamp. Observe only the CLI and files.
date = bin_dir / "date"
date.write_text('''#!/usr/bin/env python3
import os
import pathlib
import signal
import sys
count = pathlib.Path(os.environ["HOME"]) / "date-count"
if count.exists():
    sys.stdout.write("123\\n")
    sys.stdout.flush()
    os.kill(os.getppid(), signal.SIGTERM)
else:
    count.touch()
    os.execv(os.environ["REAL_DATE"], ["date", *sys.argv[1:]])
''')
date.chmod(0o700)
timestamp = state / "last-fetch"
timestamp.write_text("0\n")
before = sorted(state.iterdir())
result = subprocess.run([tool, "pull"], env=environment, capture_output=True, timeout=5)
assert result.returncode != 0, "interrupted pull reported success"
assert timestamp.read_text() == "0\n", "interrupt published an incomplete timestamp"
assert sorted(state.iterdir()) == before, "interrupt left a lock or temporary timestamp"
date.unlink()

# A real encrypted SSH key exercises terminal prompting without any network.
key = home / "ssh-key"
result = subprocess.run(["ssh-keygen", "-y", "-f", str(key)],
                        stdin=subprocess.DEVNULL, capture_output=True,
                        start_new_session=True, timeout=5)
assert result.returncode != 0, "SSH fixture was not passphrase protected"
ssh = bin_dir / "ssh"
ssh.write_text('''#!/bin/sh
exec ssh-keygen -y -f "$HOME/ssh-key"
''')
ssh.chmod(0o700)
git = bin_dir / "git"
git.write_text('''#!/bin/sh
for argument do
    case $argument in
        fetch)
            # Git itself evaluates GIT_SSH_COMMAND as shell code. This fixture
            # replaces its network transport with the local encrypted key.
            sh -c "$GIT_SSH_COMMAND review.invalid"
            printf done > "$HOME/auth-finished"
            exit 1
            ;;
    esac
done
exec "$REAL_GIT" "$@"
''')
git.chmod(0o700)
subprocess.run(["git", "-C", str(store), "config", "core.sshCommand",
                "ssh -oBatchMode=no"], check=True)
subprocess.run([tool, "config", "sync_interval", "0"], check=True)
environment.pop("DISPLAY", None)
environment["SSH_ASKPASS_REQUIRE"] = "never"
pid, terminal = pty.fork()
if pid == 0:
    os.execve(tool, [tool, "run", "--", "sh", "-c",
                    'printf ready; while [ ! -f "$HOME/foreground-release" ]; do sleep 0.1; done'],
              environment)
reaped = False
output = b""
try:
    deadline = time.monotonic() + 5
    while not (home / "auth-finished").exists():
        assert time.monotonic() < deadline, "background authentication waited for terminal input"
        if select.select([terminal], [], [], 0.05)[0]:
            output += os.read(terminal, 4096)
    (home / "foreground-release").touch()
    while True:
        ended, status = os.waitpid(pid, os.WNOHANG)
        if ended:
            reaped = True
            assert os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0
            break
        assert time.monotonic() < deadline, "foreground command did not finish"
        time.sleep(0.02)
    while select.select([terminal], [], [], 0)[0]:
        try:
            data = os.read(terminal, 4096)
        except OSError:
            break
        if not data:
            break
        output += data
    assert output == b"ready", "background authentication printed into the terminal"
    # Wait through the ordinary CLI lock before checking background cleanup.
    subprocess.run([tool, "config", "sync_interval", "14400"], check=True, timeout=5)
    assert sorted(state.iterdir()) == before, "background failure left local temporary state"
finally:
    if not reaped:
        os.killpg(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    os.close(terminal)
PY
