#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

# Interval edits are machine-local, atomic and independent of other settings.
"$ENVY_BIN" config quiet on
"$ENVY_BIN" config sync_interval 0008
"$ENVY_BIN" config > "$HOME/settings"
printf 'ambient=on\nquiet=on\nsync_interval=0008\n' > "$HOME/expected-settings"
cmp "$HOME/expected-settings" "$HOME/settings" || fail 'interval edit lost settings'
cp "$XDG_CONFIG_HOME/envy/config" "$HOME/settings-backup"
for interval in '' -1 1.5 '+2' '1 2' "\$(false)"; do
    if "$ENVY_BIN" config sync_interval "$interval" > "$HOME/invalid.out" 2> "$HOME/invalid.err"; then
        fail 'invalid interval was accepted'
    fi
    if [ -s "$HOME/invalid.out" ] || [ ! -s "$HOME/invalid.err" ]; then
        fail 'invalid interval lacked a diagnostic'
    fi
    cmp "$HOME/settings-backup" "$XDG_CONFIG_HOME/envy/config" || fail 'invalid interval changed settings'
done
"$ENVY_BIN" config sync_interval 14400
python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-refresh-passphrase
throwaway-refresh-passphrase
RESPONSES
printf 'cached throwaway credential' | "$ENVY_BIN" set TOKEN
cat > "$HOME/editor" <<'EDITOR'
#!/bin/sh
printf 'REFRESH_TOKEN=TOKEN\n' > "$1"
EDITOR
chmod +x "$HOME/editor"
EDITOR=$HOME/editor "$ENVY_BIN" project edit --global

mkdir -p "$HOME/peer"
env HOME="$HOME/peer" XDG_DATA_HOME="$HOME/peer/data" \
    XDG_CONFIG_HOME="$HOME/peer/config" XDG_STATE_HOME="$HOME/peer/state" \
    GIT_CONFIG_GLOBAL="$HOME/peer/.gitconfig" \
    python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-refresh-passphrase
RESPONSES

# Delay only Git fetch, then perform the real operation against the local bare
# remote. A release file and bounded Python waits make failures unable to hang.
REAL_GIT=$(command -v git)
SYNC_TEST_DIR=$HOME/sync-control
export REAL_GIT SYNC_TEST_DIR
mkdir -p "$SYNC_TEST_DIR/bin" "$HOME/bin" "$HOME/work/subdir"
ln -s "$ENVY_BIN" "$HOME/bin/envy"
cat > "$SYNC_TEST_DIR/bin/git" <<'GIT'
#!/bin/sh
for argument do
    case $argument in
        fetch)
            printf 'fetch\n' >> "$SYNC_TEST_DIR/events"
            printf '%s\n' 'deliberately noisy fetch' >&2
            python3 - "$SYNC_TEST_DIR" <<'PY' || exit 1
import pathlib
import os
import sys
import time
root = pathlib.Path(sys.argv[1])
assert os.environ.get("GIT_TERMINAL_PROMPT") == "0", "background Git may prompt"
assert os.environ.get("GIT_ASKPASS") == "false", "background Git may use askpass"
assert os.environ.get("SSH_ASKPASS") == "false", "background SSH may use askpass"
assert os.environ.get("GIT_SSH_COMMAND") == "ssh -i '/throwaway key path' -oBatchMode=yes", "background SSH lost configuration or may prompt"
deadline = time.monotonic() + 15
while not (root / "release").exists():
    if time.monotonic() > deadline:
        sys.exit(1)
    time.sleep(0.02)
PY
            "$REAL_GIT" "$@"
            result=$?
            printf 'fetched\n' >> "$SYNC_TEST_DIR/events"
            exit "$result"
            ;;
        push)
            "$REAL_GIT" "$@"
            result=$?
            printf 'pushed\n' >> "$SYNC_TEST_DIR/events"
            exit "$result"
            ;;
    esac
done
exec "$REAL_GIT" "$@"
GIT
chmod +x "$SYNC_TEST_DIR/bin/git"

python3 - <<'PY'
import os
import pathlib
import subprocess
import sys
import termios
import time

sys.path.insert(0, str(pathlib.Path(os.environ["TEST_ROOT"]) / "tests"))
sys.dont_write_bytecode = True
from pty_support import PtyProcess, kill_process_group

home = pathlib.Path(os.environ["HOME"])
root = pathlib.Path(os.environ["SYNC_TEST_DIR"])
tool = os.environ["ENVY_BIN"]
real_git = os.environ["REAL_GIT"]
store = pathlib.Path(os.environ["XDG_DATA_HOME"]) / "envy/store"
last_fetch = pathlib.Path(os.environ["XDG_STATE_HOME"]) / "envy/last-fetch"
lock = pathlib.Path(os.environ["XDG_STATE_HOME"]) / "envy/lock"
original_env = os.environ.copy()
env = original_env.copy()
env["PATH"] = str(root / "bin") + ":" + str(home / "bin") + ":" + env["PATH"]
peer = original_env.copy()
peer.update(HOME=str(home / "peer"), XDG_DATA_HOME=str(home / "peer/data"),
            XDG_CONFIG_HOME=str(home / "peer/config"), XDG_STATE_HOME=str(home / "peer/state"),
            GIT_CONFIG_GLOBAL=str(home / "peer/.gitconfig"))
children = []
terminals = []


def run(*args, environment=env, data=None, timeout=4):
    result = subprocess.run(args, env=environment, input=data, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=timeout)
    assert result.returncode == 0, "CLI command failed"
    assert not result.stderr, "CLI command emitted unexpected diagnostics"
    return result.stdout


def events():
    return (root / "events").read_text().splitlines() if (root / "events").exists() else []


def wait_for(predicate, message):
    deadline = time.monotonic() + 10
    while not predicate():
        assert time.monotonic() < deadline, message
        time.sleep(0.02)


def configure(interval):
    run(tool, "config", "sync_interval", str(interval), timeout=6)


def finish_refresh():
    (root / "release").touch()
    wait_for(lambda: "pushed" in events(), "detached refresh did not finish")
    # A normal locked CLI command also waits for sync cleanup before proceeding.
    configure(14400)


def reset():
    (root / "events").write_text("")
    (root / "release").unlink(missing_ok=True)


def read_value(expected):
    assert run(tool, "run", "--", "sh", "-c", 'printf "%s" "$REFRESH_TOKEN"', timeout=2) == expected, "wrong cached environment"


try:
    run(real_git, "-C", str(store), "config", "core.sshCommand", "ssh -i '/throwaway key path'")
    assert last_fetch.read_text().strip().isdigit(), "init did not record fetch time"
    initial_fetch = last_fetch.read_bytes()
    read_value(b"cached throwaway credential")
    run(tool, "hook-env", timeout=2)
    # Explicit env and cached secret reads never schedule a refresh.
    configure(0)
    run(tool, "env")
    run(tool, "get", "TOKEN")
    run(tool, "ls")
    configure(14400)
    time.sleep(0.2)
    assert events() == [], "fresh or ordinary reads touched the remote"
    assert last_fetch.read_bytes() == initial_fetch, "read rewrote fetch time"

    # Huge and leading-zero intervals must not overflow or become shell octal.
    for interval in ("00000014400", "999999999999999999999999999999"):
        configure(interval)
        read_value(b"cached throwaway credential")
    time.sleep(0.2)
    assert events() == [], "valid long or leading-zero interval triggered a fetch"

    run(tool, "set", "TOKEN", environment=peer, data=b"refreshed throwaway credential")
    configure(0)
    read_value(b"cached throwaway credential")
    wait_for(lambda: events() == ["fetch"], "stale run did not start detached fetch")
    assert last_fetch.read_bytes() == initial_fetch, "unfinished fetch recorded success"
    # The remote is blocked, yet the next read also completes immediately.
    read_value(b"cached throwaway credential")
    (root / "release").touch()
    wait_for(lambda: events().count("pushed") >= 2, "queued stale reads did not finish")
    configure(14400)
    assert last_fetch.read_text().strip().isdigit(), "fetch time was not recorded"
    assert run(real_git, "-C", str(store), "rev-parse", "HEAD") == run(real_git, "--git-dir=" + os.environ["TEST_REMOTE"], "rev-parse", "HEAD"), "background sync did not converge"
    read_value(b"refreshed throwaway credential")

    # Exercise a persistent interactive shell: same-directory prompts keep the
    # old value; a directory change observes the newly fetched store revision.
    for shell in ("bash", "zsh"):
        reset()
        configure(14400)
        old = (shell + " cached throwaway credential").encode()
        new = (shell + " refreshed throwaway credential").encode()
        run(tool, "set", "TOKEN", data=old)
        run(tool, "pull", environment=original_env)  # establish a fresh timestamp
        reset()
        script = '''
set -eu
cd "$HOME/work"
eval "$(envy hook)"
_envy_hook
printf '%s' "$REFRESH_TOKEN" > "$SYNC_TEST_DIR/loaded"
printf ready > "$SYNC_TEST_DIR/ready"
while [ ! -f "$SYNC_TEST_DIR/trigger" ]; do sleep 0.05; done
cd subdir
_envy_hook
printf '%s' "$REFRESH_TOKEN" > "$SYNC_TEST_DIR/during"
printf triggered > "$SYNC_TEST_DIR/triggered"
while [ ! -f "$SYNC_TEST_DIR/next" ]; do sleep 0.05; done
_envy_hook
printf '%s' "$REFRESH_TOKEN" > "$SYNC_TEST_DIR/same-directory"
cd ..
_envy_hook
printf '%s' "$REFRESH_TOKEN" > "$SYNC_TEST_DIR/after"
'''
        for name in ("ready", "trigger", "triggered", "next"):
            (root / name).unlink(missing_ok=True)
        session = subprocess.Popen([shell, "-c", script], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        children.append(session)
        wait_for(lambda: (root / "ready").exists(), "shell did not load cached mapping")
        assert (root / "loaded").read_bytes() == old, "shell did not load cached value"
        run(tool, "pull", environment=peer)
        run(tool, "set", "TOKEN", environment=peer, data=new)
        # Age the recorded timestamp rather than sleeping for the interval.
        last_fetch.write_text("0\n")
        (root / "trigger").touch()
        wait_for(lambda: (root / "triggered").exists(), "hook waited for the remote")
        wait_for(lambda: events() == ["fetch"], "fingerprint hit did not trigger detached sync")
        assert (root / "during").read_bytes() == old, "hook did not use its buffered environment"
        finish_refresh()
        (root / "next").touch()
        output, error = session.communicate(timeout=4)
        assert session.returncode == 0 and not output and not error, "background output reached the shell"
        assert (root / "same-directory").read_bytes() == old, "same-directory prompt unexpectedly refreshed"
        assert (root / "after").read_bytes() == new, "directory change missed background changes"

    # A foreground writer owns the lock while background requests queue. After
    # release, queued requests recheck freshness and make only one fetch.
    reset()
    configure(14400)
    holder = PtyProcess([tool, "set", "HELD"], env=env)
    terminals.append(holder)
    children.append(holder)
    terminal = holder.terminal
    holder.expect(b"Secret value: ", timeout=6)
    assert not termios.tcgetattr(terminal)[3] & termios.ECHO, "writer did not hide input"
    last_fetch.write_text("0\n")
    read_value(new)
    run(tool, "hook-env", timeout=2)
    time.sleep(0.3)
    assert events() == [], "background sync ignored the writer lock"
    os.write(terminal, b"held throwaway credential\n")
    holder.communicate(timeout=4)
    assert holder.returncode == 0, "held writer failed"
    assert b"held throwaway credential" not in holder.output, "writer echoed its secret"
    assert termios.tcgetattr(terminal) == holder.original_state, "writer did not restore terminal state"
    # Ignore the writer's push when waiting for the refresh's own push.
    wait_for(lambda: "fetch" in events(), "queued refresh did not start")
    (root / "release").touch()
    wait_for(lambda: events().count("pushed") == 2, "queued refresh did not finish")
    configure(14400)
    time.sleep(1.2)
    assert not lock.exists(), "completed writer and refresh left a lock"
    assert events().count("fetch") == 1, "queued refresh failed to recheck freshness"
    assert run(tool, "get", "HELD") == b"held throwaway credential", "background sync lost a concurrent write"
    assert run(real_git, "-C", str(store), "status", "--porcelain") == b"", "background sync dirtied store"

    # An unreachable local remote cannot delay or fail foreground reads, and
    # a failed fetch must preserve the last successful timestamp.
    reset()
    run(real_git, "-C", str(store), "remote", "set-url", "origin", str(home / "missing.git"))
    last_fetch.write_text("0\n")
    read_value(new)
    run(tool, "hook-env", timeout=2)
    wait_for(lambda: "fetch" in events(), "offline stale store did not try background refresh")
    (root / "release").touch()
    wait_for(lambda: events().count("fetched") == 2, "offline workers did not finish")
    configure(14400)
    assert last_fetch.read_text() == "0\n", "failed fetch overwrote last success"
    run(real_git, "-C", str(store), "remote", "set-url", "origin", os.environ["TEST_REMOTE"])
    # Missing timestamps also trigger recovery, including with ambient disabled.
    reset()
    last_fetch.unlink()
    run(tool, "config", "ambient", "off")
    run(tool, "hook-env", timeout=2)
    wait_for(lambda: events() == ["fetch"], "missing timestamp did not trigger refresh")
    finish_refresh()
    assert last_fetch.read_text().strip().isdigit(), "refresh did not repair missing timestamp"
finally:
    (root / "release").touch()
    (root / "trigger").touch()
    (root / "next").touch()
    for process in children:
        if process.poll() is None:
            kill_process_group(process.pid)
            process.communicate(timeout=4)
    for process in terminals:
        process.close()
PY
