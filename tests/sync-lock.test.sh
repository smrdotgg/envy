#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-lock-passphrase
throwaway-lock-passphrase
RESPONSES

# Hold set at its terminal prompt to coordinate through observable CLI output.
python3 - <<'PY'
import os
import pathlib
import pty
import select
import signal
import subprocess
import time

tool = os.environ["ENVY_BIN"]
store = pathlib.Path(os.environ["XDG_DATA_HOME"]) / "envy/store"
lock = pathlib.Path(os.environ["XDG_STATE_HOME"]) / "envy/lock"
remote = os.environ["TEST_REMOTE"]
children = []
terminals = []


def run(*args):
    return subprocess.check_output(args, timeout=15)


def start(*args, value=None):
    process = subprocess.Popen(
        [tool, *args], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, start_new_session=True,
    )
    children.append(process)
    if value is not None:
        process.stdin.write(value)
        process.stdin.close()
        process.stdin = None
    return process


def start_held(name):
    terminal, slave = pty.openpty()
    terminals.append(terminal)
    process = subprocess.Popen(
        [tool, "set", name], stdin=slave, stdout=slave, stderr=slave,
        start_new_session=True,
    )
    os.close(slave)
    children.append(process)
    output = b""
    deadline = time.monotonic() + 10
    while b"Secret value: " not in output:
        assert process.poll() is None, "set exited before prompting"
        assert time.monotonic() < deadline, "set did not prompt"
        if select.select([terminal], [], [], 0.1)[0]:
            output += os.read(terminal, 4096)
    return process, terminal


def finish(process):
    output, error = process.communicate(timeout=25)
    assert process.returncode == 0, "concurrent envy command failed"
    assert not error, "concurrent command produced an error"
    return output


try:
    finish(start("set", "CACHED", value=b"cached throwaway value"))
    holder, terminal = start_held("HELD")
    writer = start("set", "WAITING", value=b"waiting throwaway value")
    sync = start("sync")
    time.sleep(0.3)
    assert writer.poll() is None and sync.poll() is None, "live lock was ignored"
    assert subprocess.check_output([tool, "get", "CACHED"], timeout=2) == b"cached throwaway value"
    assert subprocess.check_output([tool, "ls"], timeout=2) == b"CACHED\n"
    os.write(terminal, b"held throwaway value\n")
    finish(holder)
    finish(writer)
    assert b"up to date" in finish(sync)
    assert run(tool, "get", "HELD") == b"held throwaway value"
    assert run(tool, "get", "WAITING") == b"waiting throwaway value"
    assert not lock.exists(), "completed commands left a lock"

    # SIGKILL bypasses cleanup. Several contenders must safely reclaim the dead
    # owner's lock, each committing only its own secret.
    dead, terminal = start_held("NEVER_COMMITTED")
    os.killpg(dead.pid, signal.SIGKILL)
    dead.communicate(timeout=10)
    assert lock.is_dir(), "killed process did not leave a stale lock to test"
    before = int(run("git", "-C", str(store), "rev-list", "--count", "HEAD"))
    writers = [
        start("set", f"CONCURRENT_{number}", value=f"throwaway value {number}".encode())
        for number in range(8)
    ]
    syncs = [start(command) for command in ("pull", "push", "sync")]
    for process in writers + syncs:
        finish(process)
    assert not lock.exists(), "stale lock was not cleared"
    assert run("git", "-C", str(store), "status", "--porcelain") == b""
    assert run("git", "-C", str(store), "rev-parse", "HEAD") == run(
        "git", "--git-dir=" + remote, "rev-parse", "HEAD"
    )
    assert int(run("git", "-C", str(store), "rev-list", "--count", "HEAD")) == before + 8
    assert not (store / "secrets/NEVER_COMMITTED.age").exists()
    for number in range(8):
        assert run(tool, "get", f"CONCURRENT_{number}") == f"throwaway value {number}".encode()
    commits = run("git", "-C", str(store), "log", "-8", "--format=%H").splitlines()
    for commit in commits:
        subject = run("git", "-C", str(store), "show", "-s", "--format=%s", commit.decode()).strip()
        paths = run("git", "-C", str(store), "diff-tree", "--no-commit-id", "--name-only", "-r", commit.decode())
        assert paths == b"secrets/" + subject[4:] + b".age\n", "a writer committed another writer's file"

    # A handled interrupt must release the lock and leave the store usable.
    interrupted, terminal = start_held("INTERRUPTED")
    os.killpg(interrupted.pid, signal.SIGTERM)
    interrupted.communicate(timeout=10)
    assert interrupted.returncode != 0, "interrupted set reported success"
    assert not lock.exists(), "interrupted command left a lock"
    run(tool, "sync")
    assert not (store / "secrets/INTERRUPTED.age").exists()
finally:
    for process in children:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=10)
    for terminal in terminals:
        os.close(terminal)
PY
