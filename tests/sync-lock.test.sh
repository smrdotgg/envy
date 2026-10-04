#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-lock-passphrase
throwaway-lock-passphrase
RESPONSES

# Use real CLI children, holding a piped set open to force lock contention.
python3 - <<'PY'
import os
import pathlib
import signal
import subprocess
import time

tool = os.environ["ENVY_BIN"]
store = pathlib.Path(os.environ["XDG_DATA_HOME"]) / "envy/store"
lock = pathlib.Path(os.environ["XDG_STATE_HOME"]) / "envy/lock"
remote = os.environ["TEST_REMOTE"]
children = []


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


def wait_for_owner(process):
    deadline = time.monotonic() + 10
    while not (lock / str(process.pid)).is_dir():
        assert process.poll() is None, "set exited before acquiring its lock"
        assert time.monotonic() < deadline, "set did not acquire its lock"
        time.sleep(0.01)


def finish(process):
    output, error = process.communicate(timeout=25)
    assert process.returncode == 0, "concurrent envy command failed"
    assert not error, "concurrent command produced an error"
    return output


try:
    finish(start("set", "CACHED", value=b"cached throwaway value"))
    holder = start("set", "HELD")
    wait_for_owner(holder)
    writer = start("set", "WAITING", value=b"waiting throwaway value")
    sync = start("sync")
    time.sleep(0.3)
    assert writer.poll() is None and sync.poll() is None, "live lock was ignored"
    assert subprocess.check_output([tool, "get", "CACHED"], timeout=2) == b"cached throwaway value"
    assert subprocess.check_output([tool, "ls"], timeout=2) == b"CACHED\n"
    holder.stdin.write(b"held throwaway value")
    holder.stdin.close()
    holder.stdin = None
    finish(holder)
    finish(writer)
    assert b"up to date" in finish(sync)
    assert run(tool, "get", "HELD") == b"held throwaway value"
    assert run(tool, "get", "WAITING") == b"waiting throwaway value"
    assert not lock.exists(), "completed commands left a lock"

    # SIGKILL bypasses cleanup. Several contenders must safely reclaim the dead
    # owner's lock, each committing only its own secret.
    dead = start("set", "NEVER_COMMITTED")
    wait_for_owner(dead)
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

    # Death between mkdir and publishing the owner must not leave an eternal lock.
    lock.mkdir()
    run(tool, "sync")
    assert not lock.exists(), "empty abandoned lock was not cleared"
finally:
    for process in children:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=10)
PY
