#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-edit-passphrase
throwaway-edit-passphrase
RESPONSES
store=$XDG_DATA_HOME/envy/store

# The editor observes only its CLI input, including permissions and the current
# value. Record paths, never plaintext; leave a backup to exercise cleanup.
cat > "$HOME/editor.py" <<'PY'
import os
import pathlib
import stat
import sys
import termios
import time

assert sys.argv[1] == "--fixture-option", "EDITOR options were not preserved"
assert len(sys.argv) == 3, "editor received unexpected arguments"
value = pathlib.Path(sys.argv[2])
home = pathlib.Path(os.environ["HOME"])
assert stat.S_IMODE(value.parent.stat().st_mode) == 0o700, "temporary directory is not private"
assert stat.S_IMODE(value.stat().st_mode) == 0o600, "plaintext file is not private"
assert value.read_bytes() == (home / "expected-current").read_bytes(), "editor did not receive the current value"
(home / "editor-path").write_text(str(value))
backup = pathlib.Path(str(value) + "~")
backup.write_bytes(value.read_bytes())
mode = os.environ.get("EDITOR_MODE", "replace")
if mode in ("replace", "fail"):
    value.write_bytes((home / "edit-input").read_bytes())
elif mode == "stdin":
    value.write_bytes(sys.stdin.buffer.read())
elif mode == "terminal":
    assert sys.stdin.isatty(), "editor did not receive terminal stdin"
    terminal = sys.stdin.fileno()
    original = termios.tcgetattr(terminal)
    hidden = original[:]
    hidden[3] &= ~termios.ECHO
    print("Secret value: ", end="", flush=True)
    termios.tcsetattr(terminal, termios.TCSANOW, hidden)
    try:
        value.write_bytes(sys.stdin.buffer.readline())
    finally:
        termios.tcsetattr(terminal, termios.TCSANOW, original)
elif mode == "remove":
    value.unlink()
elif mode == "symlink":
    value.unlink()
    value.symlink_to(home / "edit-input")
elif mode == "wait":
    (home / "editor-ready").write_text(str(os.getpid()))
    time.sleep(30)
elif mode != "unchanged":
    raise AssertionError("unknown fixture mode")
if mode == "fail":
    sys.exit(23)
PY
EDITOR="python3 $HOME/editor.py --fixture-option"
export EDITOR

assert_clean_edit() {
    python3 - <<'PY'
import os
import pathlib
value = pathlib.Path(os.environ["HOME"], "editor-path").read_text()
assert not pathlib.Path(value).parent.exists(), "editor plaintext or backup survived"
data = pathlib.Path(os.environ["XDG_DATA_HOME"], "envy")
assert sorted(p.name for p in data.iterdir()) == ["identity", "store"], "temporary files survived"
assert not pathlib.Path(os.environ["XDG_STATE_HOME"], "envy", "lock").exists(), "edit kept the store lock"
PY
    assert_equal "$(git -C "$store" status --porcelain)" '' 'edit left a dirty store'
}

# Creation, replacement, trailing newlines, no final newline and empty values.
: > "$HOME/expected-current"
printf '%s\n' '-----BEGIN FIXTURE-----' 'throwaway multiline '\'' " \\ $ `' 'second line' '-----END FIXTURE-----' '' > "$HOME/edit-input"
for input in multiline single empty; do
    case $input in
        multiline) ;;
        single) printf '%s' 'throwaway value without final newline' > "$HOME/edit-input" ;;
        empty) : > "$HOME/edit-input" ;;
    esac
    before=$(git -C "$store" rev-list --count HEAD)
    "$ENVY_BIN" edit KEY > edit.out 2> edit.err
    [ ! -s edit.out ] && [ ! -s edit.err ] || fail 'successful edit produced output'
    "$ENVY_BIN" get KEY > actual
    cmp "$HOME/edit-input" actual || fail 'edited value did not round trip exactly'
    assert_equal "$(git -C "$store" rev-list --count HEAD)" "$((before + 1))" 'edit did not create exactly one commit'
    assert_equal "$(git -C "$store" log -1 --format=%s)" 'edit KEY' 'edit commit subject'
    assert_equal "$(git -C "$store" diff-tree --no-commit-id --name-only -r HEAD)" secrets/KEY.age 'edit committed unrelated files'
    assert_equal "$(git -C "$store" rev-parse HEAD)" "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" 'edit did not push'
    git --git-dir="$TEST_REMOTE" show HEAD:secrets/KEY.age > remote.age
    age -d -i "$XDG_DATA_HOME/envy/identity" remote.age > remote-value 2> /dev/null
    cmp "$HOME/edit-input" remote-value || fail 'remote value differs from edited value'
    assert_clean_edit
    cp "$HOME/edit-input" "$HOME/expected-current"
    revision=$(git -C "$store" rev-parse HEAD)
    EDITOR_MODE=unchanged "$ENVY_BIN" edit KEY
    assert_equal "$(git -C "$store" rev-parse HEAD)" "$revision" 'unchanged edit created a commit'
    assert_equal "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" "$revision" 'unchanged edit changed remote history'
    assert_clean_edit
done

# Leaving a new file empty still creates the missing secret.
EDITOR_MODE=unchanged "$ENVY_BIN" edit EMPTY
"$ENVY_BIN" get EMPTY > actual
[ ! -s actual ] || fail 'new empty secret changed bytes'
assert_clean_edit

# An unset or empty EDITOR falls back to vi. Editors retain piped stdin too.
mkdir "$HOME/bin"
cat > "$HOME/bin/vi" <<'VI'
#!/bin/sh
exec python3 "$HOME/editor.py" --fixture-option "$@"
VI
chmod +x "$HOME/bin/vi"
printf 'throwaway fallback value\n\n' > "$HOME/edit-input"
for fallback in unset empty; do
    if [ "$fallback" = unset ]; then
        (unset EDITOR; PATH="$HOME/bin:$PATH" "$ENVY_BIN" edit FALLBACK)
    else
        EDITOR= PATH="$HOME/bin:$PATH" "$ENVY_BIN" edit FALLBACK
    fi
    "$ENVY_BIN" get FALLBACK > actual
    cmp "$HOME/edit-input" actual || fail 'vi fallback did not save'
    cp "$HOME/edit-input" "$HOME/expected-current"
    assert_clean_edit
done
EDITOR_MODE=stdin "$ENVY_BIN" edit FALLBACK < "$HOME/edit-input"
"$ENVY_BIN" get FALLBACK > actual
cmp "$HOME/edit-input" actual || fail 'editor did not receive piped stdin'
assert_clean_edit
printf 'throwaway terminal edited value\n' > "$HOME/edit-input"
EDITOR_MODE=terminal python3 "$TEST_ROOT/tests/pty-helper.py" --transcript edit-terminal -- "$ENVY_BIN" edit FALLBACK < "$HOME/edit-input"
python3 - <<'PY'
import os
import pathlib
output = pathlib.Path('edit-terminal').read_bytes()
value = pathlib.Path(os.environ['HOME'], 'edit-input').read_bytes().rstrip(b'\n')
assert value not in output, 'editor terminal exposed a secret value'
assert b'throwaway-edit-passphrase' not in output, 'editor terminal exposed a passphrase'
PY
"$ENVY_BIN" get FALLBACK > actual
cmp "$HOME/edit-input" actual || fail 'editor did not receive terminal input'
cp "$HOME/edit-input" "$HOME/expected-current"
assert_clean_edit

# Failed, missing and redirected editor output must preserve ciphertext/history.
revision=$(git -C "$store" rev-parse HEAD)
cp "$store/secrets/FALLBACK.age" saved.age
for mode in fail remove symlink; do
    if EDITOR_MODE=$mode "$ENVY_BIN" edit FALLBACK > failure.out 2> failure.err; then
        fail 'invalid editor result was saved'
    fi
    [ ! -s failure.out ] || fail 'failed edit printed stdout'
    grep 'secret not saved' failure.err > /dev/null || fail 'failed edit not diagnosed'
    cmp saved.age "$store/secrets/FALLBACK.age" || fail 'failed edit changed ciphertext'
    assert_equal "$(git -C "$store" rev-parse HEAD)" "$revision" 'failed edit created a commit'
    assert_clean_edit
done
: > "$HOME/expected-current"
if EDITOR_MODE=fail "$ENVY_BIN" edit FAILED_NEW > failure.out 2> failure.err; then
    fail 'failed editor created a secret'
fi
[ ! -e "$store/secrets/FAILED_NEW.age" ] || fail 'failed editor left a new secret'
assert_clean_edit

# Reject invalid arguments and unsafe store state before opening the editor.
rm "$HOME/editor-path"
for name in '' lowercase 1DIGIT '../ESCAPE' 'A B'; do
    if "$ENVY_BIN" edit "$name" > rejected.out 2> rejected.err; then
        fail 'invalid edit name accepted'
    fi
    grep 'invalid secret name' rejected.err > /dev/null || fail 'invalid edit name not diagnosed'
done
# Split only the fixed argument table below, with pathname expansion disabled.
set -f
for args in '' 'KEY extra'; do
    # Intentional splitting of the fixed table above; globbing is disabled.
    # shellcheck disable=SC2086
    set -- $args
    if "$ENVY_BIN" edit "$@" > rejected.out 2> rejected.err; then
        fail 'invalid edit arguments accepted'
    fi
    grep 'usage: envy edit NAME' rejected.err > /dev/null || fail 'edit argument error lacks usage'
done
set +f
printf '%s\n' unrelated > "$store/unrelated"
if "$ENVY_BIN" edit KEY > rejected.out 2> rejected.err; then
    fail 'edit accepted a dirty store'
fi
grep 'store has uncommitted changes' rejected.err > /dev/null || fail 'dirty edit not diagnosed'
rm "$store/unrelated"
cp "$store/recipient" saved-recipient
age-keygen -o alternate-identity 2> /dev/null
age-keygen -y alternate-identity > "$store/recipient"
if "$ENVY_BIN" edit KEY > rejected.out 2> rejected.err; then
    fail 'edit accepted a recipient mismatch'
fi
grep 'run envy unlock' rejected.err > /dev/null || fail 'edit mismatch lacks unlock advice'
mv saved-recipient "$store/recipient"
printf '%s\n' 'invalid ciphertext' > "$store/secrets/KEY.age"
git -C "$store" add secrets/KEY.age
git -C "$store" -c user.name=fixture -c user.email=fixture@localhost commit --quiet -m 'fixture corrupt ciphertext'
if "$ENVY_BIN" edit KEY > rejected.out 2> rejected.err; then
    fail 'edit accepted corrupt ciphertext'
fi
grep 'could not decrypt secret: KEY' rejected.err > /dev/null || fail 'corrupt edit not diagnosed'
[ ! -e "$HOME/editor-path" ] || fail 'rejected edit opened editor'
git -C "$store" reset --quiet --hard "$revision"

# Interrupt a waiting editor, both the command alone and its process group.
# A timeout and process-group cleanup ensure a regression cannot hang the gate.
cp "$HOME/edit-input" "$HOME/expected-current"
python3 - <<'PY'
import os
import pathlib
import signal
import subprocess
import time

home = pathlib.Path(os.environ["HOME"])
data = pathlib.Path(os.environ["XDG_DATA_HOME"], "envy")
store = data / "store"
tool = os.environ["ENVY_BIN"]
revision = subprocess.check_output(["git", "-C", str(store), "rev-parse", "HEAD"])
remote = subprocess.check_output(["git", "--git-dir=" + os.environ["TEST_REMOTE"], "rev-parse", "HEAD"])
for sig, group in ((signal.SIGINT, False), (signal.SIGTERM, False), (signal.SIGHUP, False), (signal.SIGINT, True)):
    ready = home / "editor-ready"
    ready.unlink(missing_ok=True)
    process = subprocess.Popen([tool, "edit", "FALLBACK"], env=dict(os.environ, EDITOR_MODE="wait"),
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    try:
        deadline = time.monotonic() + 10
        while not ready.exists():
            assert process.poll() is None, "edit exited before opening editor"
            assert time.monotonic() < deadline, "editor did not become ready"
            time.sleep(0.02)
        value = pathlib.Path((home / "editor-path").read_text())
        assert value.exists(), "editor did not receive plaintext"
        if group:
            os.killpg(process.pid, sig)
        else:
            process.send_signal(sig)
        stdout, stderr = process.communicate(timeout=5)
        assert process.returncode != 0, "interrupted edit succeeded"
        assert not stdout, "interrupted edit printed stdout"
        assert not value.parent.exists(), "interrupted edit retained plaintext or backup"
        assert sorted(p.name for p in data.iterdir()) == ["identity", "store"], "interrupted edit left files"
        assert not pathlib.Path(os.environ["XDG_STATE_HOME"], "envy", "lock").exists(), "interrupted edit kept lock"
        assert subprocess.check_output(["git", "-C", str(store), "rev-parse", "HEAD"]) == revision, "interrupt committed"
        assert subprocess.check_output(["git", "--git-dir=" + os.environ["TEST_REMOTE"], "rev-parse", "HEAD"]) == remote, "interrupt pushed"
        assert subprocess.check_output(["git", "-C", str(store), "status", "--porcelain"]) == b"", "interrupt dirtied store"
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)
PY
assert_clean_edit

# A saved edit clears only its pending rotation mark in the same pushed commit.
# Unchanged content and failed editors leave the pending list untouched.
printf '%s\n' FALLBACK KEY > "$store/rotation-pending"
git -C "$store" add rotation-pending
git -C "$store" commit --quiet -m 'fixture pending rotation'
revision=$(git -C "$store" rev-parse HEAD)
cp "$store/rotation-pending" expected-pending
EDITOR_MODE=unchanged "$ENVY_BIN" edit FALLBACK
assert_equal "$(git -C "$store" rev-parse HEAD)" "$revision" 'unchanged pending edit created a commit'
cmp expected-pending "$store/rotation-pending" || fail 'unchanged edit cleared a pending mark'
if EDITOR_MODE=fail "$ENVY_BIN" edit FALLBACK > failure.out 2> failure.err; then
    fail 'failed pending edit succeeded'
fi
cmp expected-pending "$store/rotation-pending" || fail 'failed edit cleared a pending mark'
assert_clean_edit
printf 'throwaway rotated edited value\n' > "$HOME/edit-input"
"$ENVY_BIN" edit FALLBACK
printf '%s\n' KEY > expected-pending
cmp expected-pending "$store/rotation-pending" || fail 'saved edit did not clear only its pending mark'
assert_equal "$(git -C "$store" rev-list --count "$revision..HEAD")" 1 'pending edit did not create one commit'
printf '%s\n' rotation-pending secrets/FALLBACK.age > expected-changes
git -C "$store" diff-tree --no-commit-id --name-only -r HEAD > changes
cmp expected-changes changes || fail 'rotation mark was not committed with ciphertext'
git --git-dir="$TEST_REMOTE" show HEAD:rotation-pending > remote-pending
cmp expected-pending remote-pending || fail 'pending rotation change was not pushed'
cp "$HOME/edit-input" "$HOME/expected-current"
assert_clean_edit

# Offline saves use the ordinary local commit and subsequent sync flow.
printf 'throwaway offline edited value\n' > "$HOME/edit-input"
git -C "$store" remote set-url origin "$HOME/absent.git"
"$ENVY_BIN" edit FALLBACK > offline.out 2> offline.err
grep 'warning:.*local commit retained' offline.err > /dev/null || fail 'offline edit did not retain commit'
"$ENVY_BIN" get FALLBACK > actual
cmp "$HOME/edit-input" actual || fail 'offline edit lost value'
assert_clean_edit
git -C "$store" remote set-url origin "$TEST_REMOTE"
"$ENVY_BIN" sync > /dev/null
assert_equal "$(git -C "$store" rev-parse HEAD)" "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" 'offline edit was not synced'

# Secret values must never enter envy diagnostics or commit messages.
git -C "$store" log --format=%B > history
if grep -F 'throwaway' history edit.out edit.err failure.out failure.err rejected.out rejected.err offline.out offline.err > /dev/null; then
    fail 'edit logged a secret value'
fi
