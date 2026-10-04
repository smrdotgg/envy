#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

homes=$HOME/machines
use_home() {
    HOME=$homes/$1
    XDG_DATA_HOME=$HOME/custom\ data
    XDG_CONFIG_HOME=$HOME/.config
    XDG_STATE_HOME=$HOME/custom\ state
    XDG_CACHE_HOME=$HOME/.cache
    GIT_CONFIG_GLOBAL=$HOME/.gitconfig
    export HOME XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME GIT_CONFIG_GLOBAL
    mkdir -p "$HOME"
}
rekey() {
    python3 "$TEST_ROOT/tests/pty-helper.py" --transcript "$1" -- "$ENVY_BIN" rekey <<'RESPONSES'
throwaway-new-rekey-passphrase
throwaway-new-rekey-passphrase
RESPONSES
}
assert_clean() {
    assert_equal "$(git -C "$store" status --porcelain)" '' 'rekey left dirty store'
    python3 - "$XDG_DATA_HOME/envy" "$XDG_STATE_HOME/envy" <<'PY'
import pathlib
import sys
assert sorted(p.name for p in pathlib.Path(sys.argv[1]).iterdir()) == ['identity', 'store']
assert not (pathlib.Path(sys.argv[2]) / 'lock').exists()
PY
}

use_home first
python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-old-rekey-passphrase
throwaway-old-rekey-passphrase
RESPONSES
store=$XDG_DATA_HOME/envy/store
first_store=$store
first_identity=$XDG_DATA_HOME/envy/identity
cp "$first_identity" old-identity
printf 'throwaway rekey value with '\''quotes\nsecond line\n\n' > expected
printf 'another throwaway rekey value' > other-value
"$ENVY_BIN" set ALPHA < expected
"$ENVY_BIN" set BETA < other-value
"$ENVY_BIN" set GAMMA < expected
cat > "$HOME/editor" <<'EDITOR'
#!/bin/sh
printf 'TOKEN=ALPHA\n' > "$1"
EDITOR
chmod +x "$HOME/editor"
EDITOR=$HOME/editor "$ENVY_BIN" project edit --global

use_home second
python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-old-rekey-passphrase
RESPONSES
second_store=$XDG_DATA_HOME/envy/store
"$ENVY_BIN" set DELTA < other-value

# Preserve a divergent old-key write, as on a laptop that was offline at rekey.
use_home isolated
python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-old-rekey-passphrase
RESPONSES
isolated_store=$XDG_DATA_HOME/envy/store
git -C "$isolated_store" remote set-url origin "$HOME/absent.git"
"$ENVY_BIN" set ISOLATED < expected > /dev/null 2> /dev/null
isolated_revision=$(git -C "$isolated_store" rev-parse HEAD)
git -C "$isolated_store" remote set-url origin "$TEST_REMOTE"
use_home first
before=$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)

# No remote means no rekey, even with a recent successful fetch on disk.
original=$(git -C "$store" rev-parse HEAD)
git -C "$store" remote set-url origin "$HOME/absent.git"
if rekey offline-terminal; then fail 'offline rekey succeeded'; fi
grep 'remote unavailable' offline-terminal > /dev/null || fail 'offline rekey lacked diagnostic'
if grep 'Enter passphrase' offline-terminal > /dev/null; then fail 'offline rekey prompted'; fi
cmp old-identity "$first_identity" || fail 'offline rekey replaced key'
assert_equal "$(git -C "$store" rev-parse HEAD)" "$original" 'offline rekey committed'
assert_clean
git -C "$store" remote set-url origin "$TEST_REMOTE"

# A dirty store also stops before the passphrase prompt.
printf 'fixture\n' > "$store/untracked"
if rekey dirty-terminal; then fail 'dirty rekey succeeded'; fi
if grep 'Enter passphrase' dirty-terminal > /dev/null; then fail 'dirty rekey prompted'; fi
rm "$store/untracked"

# A failed passphrase flow leaves only the successfully pulled snapshot.
python3 - <<'PY'
import os
import subprocess
result = subprocess.run([os.environ['ENVY_BIN'], 'rekey'], stdin=subprocess.DEVNULL,
                        capture_output=True, start_new_session=True, timeout=10)
assert result.returncode != 0
assert b'could not protect identity' in result.stderr
PY
assert_equal "$(git -C "$store" rev-parse HEAD)" "$before" 'failed rekey did not retain pulled snapshot'
cmp old-identity "$first_identity" || fail 'failed passphrase replaced identity'
assert_clean

# Interrupting a passphrase prompt cleans temporary keys and releases the lock.
python3 - <<'PY'
import os
import pty
import select
import signal
import time

pid, terminal = pty.fork()
if pid == 0:
    os.execv(os.environ['ENVY_BIN'], [os.environ['ENVY_BIN'], 'rekey'])
reaped = False
try:
    output = b''
    deadline = time.monotonic() + 10
    while b'Enter passphrase' not in output:
        assert time.monotonic() < deadline, 'rekey did not prompt'
        if select.select([terminal], [], [], 0.1)[0]:
            output += os.read(terminal, 4096)
    os.killpg(pid, signal.SIGTERM)
    while True:
        ended, status = os.waitpid(pid, os.WNOHANG)
        if ended:
            reaped = True
            assert not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0
            break
        assert time.monotonic() < deadline, 'interrupted rekey did not exit'
        time.sleep(0.01)
finally:
    if not reaped:
        os.killpg(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    os.close(terminal)
PY
cmp old-identity "$first_identity" || fail 'interrupted rekey replaced identity'
assert_equal "$(git -C "$store" rev-parse HEAD)" "$before" 'interrupted rekey changed history'
assert_clean

# Stage all ciphertext first: even a late decrypt failure must preserve files.
cp "$store/secrets/GAMMA.age" saved-gamma.age
printf 'invalid fixture ciphertext\n' > "$store/secrets/GAMMA.age"
git -C "$store" add secrets/GAMMA.age
git -C "$store" commit --quiet -m 'fixture corrupt ciphertext'
corrupt=$(git -C "$store" rev-parse HEAD)
if rekey corrupt-terminal; then fail 'corrupt secret accepted'; fi
grep 'could not decrypt secret: GAMMA' corrupt-terminal > /dev/null || fail 'corrupt secret lacks safe diagnostic'
assert_equal "$(git -C "$store" rev-parse HEAD)" "$corrupt" 'decrypt failure changed history'
cmp old-identity "$first_identity" || fail 'decrypt failure replaced identity'
assert_clean
mv saved-gamma.age "$store/secrets/GAMMA.age"
git -C "$store" add secrets/GAMMA.age
git -C "$store" commit --quiet -m 'fixture repair ciphertext'
"$ENVY_BIN" sync > /dev/null
before=$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)

# A commit failure rolls back the staged store and identity together.
real_git=$(command -v git)
export real_git
mkdir "$HOME/bin"
cat > "$HOME/bin/git" <<'GIT'
#!/bin/sh
for arg do
    if [ "$arg" = commit ]; then exit 1; fi
done
exec "$real_git" "$@"
GIT
chmod +x "$HOME/bin/git"
original_path=$PATH
PATH=$HOME/bin:$PATH
export PATH
if rekey commit-terminal; then fail 'failed commit accepted'; fi
grep 'could not commit store changes' commit-terminal > /dev/null || fail 'commit failure lacks diagnostic'
PATH=$original_path
export PATH
assert_equal "$(git -C "$store" rev-parse HEAD)" "$before" 'commit failure changed history'
cmp old-identity "$first_identity" || fail 'commit failure replaced identity'
assert_clean

rekey rekey-terminal
assert_equal "$(git -C "$store" rev-list --count "$before..HEAD")" 1 'rekey did not make one commit'
assert_equal "$(git -C "$store" rev-parse HEAD^)" "$before" 'rekey failed to pull remote secret first'
assert_equal "$(git -C "$store" rev-parse HEAD)" "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" 'rekey was not pushed'
assert_equal "$(git -C "$store" log -1 --format=%s)" 'rekey store' 'rekey commit message'
if cmp -s old-identity "$first_identity"; then fail 'rekey kept old identity'; fi
printf 'ALPHA\nBETA\nDELTA\nGAMMA\n' > pending
cmp pending "$store/rotation-pending" || fail 'rekey did not mark every secret'
git --git-dir="$TEST_REMOTE" show HEAD:rotation-pending > remote-pending
cmp pending remote-pending || fail 'pending list was not pushed'
for name in ALPHA BETA DELTA GAMMA; do
    grep "^$name" rekey-terminal > /dev/null || fail 'rekey omitted rotation notice'
    "$ENVY_BIN" get "$name" > actual
    case $name in ALPHA|GAMMA) cmp expected actual ;; *) cmp other-value actual ;; esac || fail 'rekey changed value bytes'
done
"$ENVY_BIN" status > status.out
grep -Fx 'Pending rotation: 4' status.out > /dev/null || fail 'status pending count'
assert_clean
python3 - rekey-terminal "$first_identity" <<'PY'
import pathlib
import re
import stat
import sys
output = pathlib.Path(sys.argv[1]).read_bytes()
assert len(re.findall(rb'(?:Enter|Confirm) passphrase[^\r\n]*?: ', output)) == 2
assert b'throwaway-new-rekey-passphrase' not in output
assert stat.S_IMODE(pathlib.Path(sys.argv[2]).stat().st_mode) == 0o600
PY

# The old key cannot read new writes; rekey does not erase historical values.
"$ENVY_BIN" set FRESH < expected
if age -d -i old-identity "$store/secrets/FRESH.age" > old-read.out 2> old-read.err; then
    fail 'old identity decrypted a post-rekey write'
fi
git -C "$store" show "$before:secrets/ALPHA.age" > historical.age
age -d -i old-identity historical.age > actual
cmp expected actual || fail 'historical ciphertext unexpectedly changed'

# Another machine pulls without prompting, then refuses reads and writes.
use_home isolated
for command in pull sync rekey; do
    if "$ENVY_BIN" "$command" < /dev/null > diverged.out 2> diverged.err; then
        fail 'divergent old-key history merged across rekey'
    fi
    grep 'sync crosses a rekey.*local commits retained' diverged.err > /dev/null || fail 'divergent rekey lacks diagnostic'
    assert_equal "$(git -C "$isolated_store" rev-parse HEAD)" "$isolated_revision" 'divergent refusal changed history'
    assert_equal "$(git -C "$isolated_store" status --porcelain)" '' 'divergent refusal dirtied store'
    "$ENVY_BIN" get ISOLATED > actual
    cmp expected actual || fail 'divergent refusal lost old-key value'
done

# A clean second machine adopts the remote snapshot without any terminal.
use_home second
"$ENVY_BIN" pull > /dev/null
cp "$XDG_DATA_HOME/envy/identity" second-old-identity
for command in get set edit ls env run check; do
    case $command in
        get|set|edit) set -- "$command" ALPHA ;;
        run) set -- run -- sh -c 'exit 99' ;;
        *) set -- "$command" ;;
    esac
    if "$ENVY_BIN" "$@" < expected > mismatch.out 2> mismatch.err; then fail 'stale identity accepted'; fi
    [ ! -s mismatch.out ] || fail 'stale identity printed exports or secrets'
    grep 'run envy unlock' mismatch.err > /dev/null || fail 'stale identity lacks unlock advice'
done
"$ENVY_BIN" hook-env < /dev/null > hook.out 2> hook.err
assert_equal "$(wc -l < hook.err | tr -d ' ')" 1 'hook error is not one line'
grep 'run envy unlock' hook.err > /dev/null || fail 'hook lacks unlock advice'
if grep '^export TOKEN=' hook.out > /dev/null; then fail 'hook loaded stale identity'; fi
if python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" unlock <<'RESPONSES'
throwaway-old-rekey-passphrase
RESPONSES
then fail 'old passphrase unlocked new identity'; fi
cmp second-old-identity "$XDG_DATA_HOME/envy/identity" || fail 'wrong unlock replaced identity'
python3 "$TEST_ROOT/tests/pty-helper.py" --transcript unlock-terminal -- "$ENVY_BIN" unlock <<'RESPONSES'
throwaway-new-rekey-passphrase
RESPONSES
cmp "$first_identity" "$XDG_DATA_HOME/envy/identity" || fail 'unlock did not install rekeyed identity'
"$ENVY_BIN" get ALPHA > actual
cmp expected actual || fail 'recovered machine cannot read'
"$ENVY_BIN" run -- sh -c 'printf "%s" "$TOKEN"' > actual
cmp expected actual || fail 'recovered run cannot load environment'
"$ENVY_BIN" hook-env > hook.out 2> hook.err
[ ! -s hook.err ] || fail 'recovered hook failed'
grep '^export TOKEN=' hook.out > /dev/null || fail 'recovered hook did not load'

# Rotation tracking follows renames; set, saved edit and removal each clear it.
use_home first
"$ENVY_BIN" mv GAMMA RENAMED > /dev/null 2> rename.err
printf 'ALPHA\nBETA\nDELTA\nRENAMED\n' > pending
cmp pending "$store/rotation-pending" || fail 'rename lost rotation mark'
"$ENVY_BIN" set ALPHA < other-value
cat > "$HOME/editor" <<'EDITOR'
#!/bin/sh
cat "$HOME/edit-value" > "$1"
EDITOR
cp expected "$HOME/edit-value"
EDITOR=$HOME/editor "$ENVY_BIN" edit BETA
"$ENVY_BIN" rm DELTA
"$ENVY_BIN" rm RENAMED
[ ! -s "$store/rotation-pending" ] || fail 'set/edit/rm left pending rotation marks'
git --git-dir="$TEST_REMOTE" show HEAD:rotation-pending > remote-pending
[ ! -s remote-pending ] || fail 'rotation clearing not pushed'
"$ENVY_BIN" status > status.out
grep -Fx 'Pending rotation: 0' status.out > /dev/null || fail 'cleared pending count'
assert_clean

# A rejected push keeps a readable committed rekey, without rebasing/retrying.
cat > "$TEST_REMOTE/hooks/pre-receive" <<'HOOK'
#!/bin/sh
printf 'attempt\n' >> "$(dirname "$0")/../../rekey-push-attempts"
exit 1
HOOK
chmod +x "$TEST_REMOTE/hooks/pre-receive"
before=$(git -C "$store" rev-parse HEAD)
if rekey rejected-terminal; then fail 'rejected rekey push reported success'; fi
grep 'rekey push failed; new local identity and commit retained' rejected-terminal > /dev/null || fail 'rejected rekey lacks recovery diagnostic'
assert_equal "$(wc -l < "$TEST_REMOTE/../rekey-push-attempts" | tr -d ' ')" 1 'rekey retried rejected push'
assert_equal "$(git -C "$store" rev-list --count "$before..HEAD")" 1 'rejected push lost rekey commit'
"$ENVY_BIN" get FRESH > actual
cmp expected actual || fail 'rejected push lost readable local secret'
assert_clean
rm "$TEST_REMOTE/hooks/pre-receive"
"$ENVY_BIN" sync > /dev/null
assert_equal "$(git -C "$store" rev-parse HEAD)" "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" 'rejected rekey could not be pushed later'

# Empty stores can also replace their identity and push a single commit.
empty_remote=$homes/empty.git
fixture_remote "$empty_remote"
use_home empty
python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$empty_remote" <<'RESPONSES'
throwaway-empty-rekey-passphrase
throwaway-empty-rekey-passphrase
RESPONSES
before=$(git --git-dir="$empty_remote" rev-parse HEAD)
rekey empty-terminal
assert_equal "$(git --git-dir="$empty_remote" rev-list --count "$before..HEAD")" 1 'empty rekey was not one pushed commit'
[ ! -s "$XDG_DATA_HOME/envy/store/rotation-pending" ] || fail 'empty rekey invented a pending secret'
python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" unlock <<'RESPONSES'
throwaway-new-rekey-passphrase
RESPONSES
use_home first

# No secret or chosen passphrase is logged by envy or in commit messages.
git --git-dir="$TEST_REMOTE" log --format=%B > history
cat rekey-terminal corrupt-terminal commit-terminal mismatch.err hook.err >> history
sed '/^$/d' expected other-value > secret-patterns
printf 'throwaway-new-rekey-passphrase\nthrowaway-old-rekey-passphrase\n' >> secret-patterns
if grep -F -f secret-patterns history > /dev/null; then fail 'rekey leaked a value or passphrase'; fi
if "$ENVY_BIN" rekey extra > args.out 2> args.err; then fail 'rekey accepted an argument'; fi
grep 'usage: envy rekey' args.err > /dev/null || fail 'rekey argument diagnostic'
