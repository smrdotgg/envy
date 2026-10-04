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

use_home first
python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-sync-passphrase
throwaway-sync-passphrase
RESPONSES
first_store=$XDG_DATA_HOME/envy/store
use_home second
python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-sync-passphrase
RESPONSES
second_store=$XDG_DATA_HOME/envy/store

printf '%s' 'first throwaway secret' > first-value
printf 'second throwaway secret\nwith a second line\n\n' > second-value
use_home first
"$ENVY_BIN" set FIRST < first-value
use_home second
# The remote is ahead: this write must rebase and retry once without attention.
"$ENVY_BIN" set SECOND < second-value > retry.out 2> retry.err
[ ! -s retry.out ] && [ ! -s retry.err ] || fail 'successful automatic retry was noisy'
assert_equal "$(git --git-dir="$TEST_REMOTE" rev-list --count HEAD)" 3 'retry created extra commits or lost one'
assert_equal "$(git -C "$second_store" rev-parse HEAD)" "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" 'retry did not push'
"$ENVY_BIN" get FIRST > actual
cmp first-value actual || fail 'rebase lost the other machine secret'
"$ENVY_BIN" get SECOND > actual
cmp second-value actual || fail 'rebase lost the local secret'
assert_equal "$(git -C "$second_store" status --porcelain)" '' 'retry left the store dirty'

use_home first
# Reads use the local snapshot until an explicit pull.
if "$ENVY_BIN" get SECOND > read.out 2> read.err; then
    fail 'read unexpectedly fetched remote changes'
fi
"$ENVY_BIN" pull > pull.out 2> pull.err
grep 'pulled remote changes' pull.out > /dev/null || fail 'pull did not report the update'
[ ! -s pull.err ] || fail 'pull produced an error'
"$ENVY_BIN" get SECOND > actual
cmp second-value actual || fail 'pull did not install the remote secret'
"$ENVY_BIN" push > push.out
grep 'remote already up to date' push.out > /dev/null || fail 'push did not report no changes'
"$ENVY_BIN" sync > sync.out
grep 'local store already up to date' sync.out > /dev/null || fail 'sync did not report its pull'
grep 'remote already up to date' sync.out > /dev/null || fail 'sync did not report its push'

# Remove local author settings to prove sync can rebase without a global identity.
git -C "$first_store" config --unset user.name
git -C "$first_store" config --unset user.email
[ ! -e "$HOME/.gitconfig" ] || fail 'envy wrote a global git identity'
remote_revision=$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)
git -C "$first_store" remote set-url origin "$HOME/absent.git"
"$ENVY_BIN" set OFFLINE < first-value > offline.out 2> offline.err
[ ! -s offline.out ] || fail 'offline write printed stdout'
grep 'warning:.*local commit retained.*envy sync' offline.err > /dev/null || fail 'offline write did not explain recovery'
assert_equal "$(git -C "$first_store" log -1 --format=%s)" 'set OFFLINE' 'offline write was not committed'
assert_equal "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" "$remote_revision" 'offline write changed the remote'
assert_equal "$(git -C "$first_store" status --porcelain)" '' 'offline write left uncommitted changes'
"$ENVY_BIN" get OFFLINE > actual
cmp first-value actual || fail 'offline value was lost'
"$ENVY_BIN" ls > offline-names
for command in pull push sync; do
    if "$ENVY_BIN" "$command" < /dev/null > unavailable.out 2> unavailable.err; then
        fail 'explicit sync command reported success while offline'
    fi
    grep 'remote unavailable.*local commits retained' unavailable.err > /dev/null || fail 'offline sync error is unclear'
done

use_home second
"$ENVY_BIN" set ONLINE < second-value
use_home first
# Both sides advanced, and sync must pull before pushing the offline commit.
git -C "$first_store" remote set-url origin "$TEST_REMOTE"
git -C "$first_store" config --unset user.name
git -C "$first_store" config --unset user.email
"$ENVY_BIN" sync > recovered.out 2> recovered.err
grep 'pulled remote changes' recovered.out > /dev/null || fail 'sync did not pull before pushing'
grep 'pushed local commits' recovered.out > /dev/null || fail 'sync did not report pushing offline commits'
[ ! -s recovered.err ] || fail 'offline recovery produced an error'
assert_equal "$(git -C "$first_store" rev-parse HEAD)" "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" 'sync did not converge'
assert_equal "$(git -C "$first_store" config --local user.name)" envy 'author name not supplied locally'
assert_equal "$(git -C "$first_store" config --local user.email)" envy@localhost 'author email not supplied locally'
"$ENVY_BIN" get ONLINE > actual
cmp second-value actual || fail 'sync lost the remote write'
use_home second
"$ENVY_BIN" pull > /dev/null
"$ENVY_BIN" get OFFLINE > actual
cmp first-value actual || fail 'offline commit did not reach the other machine'

# Explicit push also gets one pull/rebase retry when another machine advanced.
use_home first
git -C "$first_store" remote set-url origin "$HOME/absent.git"
"$ENVY_BIN" set PUSH_LOCAL < first-value > /dev/null 2> /dev/null
use_home second
"$ENVY_BIN" set PUSH_REMOTE < second-value
use_home first
git -C "$first_store" remote set-url origin "$TEST_REMOTE"
"$ENVY_BIN" push > retry-push.out
grep 'pulled remote changes' retry-push.out > /dev/null || fail 'push did not report its retry pull'
grep 'pushed local commits' retry-push.out > /dev/null || fail 'push did not send the local commit'
"$ENVY_BIN" get PUSH_REMOTE > actual
cmp second-value actual || fail 'push retry lost the remote secret'

# A reachable remote that rejects writes must receive only two push attempts.
cat > "$TEST_REMOTE/hooks/pre-receive" <<'HOOK'
#!/bin/sh
printf '%s\n' attempt >> "$(dirname "$0")/../../push-attempts"
exit 1
HOOK
chmod +x "$TEST_REMOTE/hooks/pre-receive"
"$ENVY_BIN" set REJECTED < first-value > rejected.out 2> rejected.err
grep 'warning:.*local commit retained' rejected.err > /dev/null || fail 'rejected write did not keep its commit with a warning'
assert_equal "$(wc -l < "$TEST_REMOTE/../push-attempts" | tr -d ' ')" 2 'write did not stop after one push retry'
if "$ENVY_BIN" push > rejected.out 2> rejected.err; then
    fail 'explicit push succeeded despite rejection'
fi
grep 'push failed after one retry.*local commits retained' rejected.err > /dev/null || fail 'repeated push rejection not explained'
assert_equal "$(wc -l < "$TEST_REMOTE/../push-attempts" | tr -d ' ')" 4 'explicit push did not stop after one retry'
rm "$TEST_REMOTE/hooks/pre-receive"
"$ENVY_BIN" sync > /dev/null
"$ENVY_BIN" get REJECTED > actual
cmp first-value actual || fail 'rejected push lost the local value'

# Refuse dirty state before either writing or rebasing; keep staged files intact.
printf '%s\n' 'fixture metadata' > "$first_store/unrelated"
git -C "$first_store" add unrelated
revision=$(git -C "$first_store" rev-parse HEAD)
for command in pull push sync set; do
    case $command in
        set) set -- set DIRTY ;;
        *) set -- "$command" ;;
    esac
    if "$ENVY_BIN" "$@" < first-value > dirty.out 2> dirty.err; then
        fail 'command accepted a dirty store'
    fi
    grep 'store has uncommitted changes' dirty.err > /dev/null || fail 'dirty store not diagnosed'
    assert_equal "$(git -C "$first_store" rev-parse HEAD)" "$revision" 'dirty refusal changed history'
    assert_equal "$(git -C "$first_store" diff --cached --name-only)" unrelated 'dirty refusal changed the index'
done
git -C "$first_store" reset --quiet -- unrelated
rm "$first_store/unrelated"

# Updating the same secret must preserve the just-written local commit on conflict.
"$ENVY_BIN" set SHARED < first-value
use_home second
"$ENVY_BIN" pull > /dev/null
baseline=$(git -C "$second_store" rev-parse HEAD)
use_home first
"$ENVY_BIN" set SHARED < first-value
remote_revision=$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)
use_home second
if "$ENVY_BIN" set SHARED < second-value > conflict.out 2> conflict.err; then
    fail 'conflicting write reported success'
fi
[ ! -s conflict.out ] || fail 'conflict printed stdout'
grep 'sync conflict.*rebase aborted.*local commits retained' conflict.err > /dev/null || fail 'conflict explanation is unclear'
revision=$(git -C "$second_store" rev-parse HEAD)
assert_equal "$(git -C "$second_store" rev-parse HEAD^)" "$baseline" 'conflict did not restore the local branch'
assert_equal "$(git -C "$second_store" log -1 --format=%s)" 'set SHARED' 'conflict lost the local write commit'
assert_equal "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" "$remote_revision" 'conflict changed the remote'
"$ENVY_BIN" get SHARED > actual
cmp second-value actual || fail 'conflict lost the local value'
cp "$second_store/secrets/SHARED.age" conflict-ciphertext
for command in pull push sync; do
    if "$ENVY_BIN" "$command" > conflict.out 2> conflict.err; then
        fail 'explicit sync command accepted a conflict'
    fi
    grep 'sync conflict.*rebase aborted' conflict.err > /dev/null || fail 'explicit conflict not explained'
    assert_equal "$(git -C "$second_store" rev-parse HEAD)" "$revision" 'conflict retry changed the local branch'
    assert_equal "$(git -C "$second_store" status --porcelain)" '' 'conflict left the store dirty'
    cmp conflict-ciphertext "$second_store/secrets/SHARED.age" || fail 'conflict retry changed ciphertext'
    [ ! -d "$second_store/.git/rebase-merge" ] && [ ! -d "$second_store/.git/rebase-apply" ] || fail 'rebase was not aborted'
done
use_home first
"$ENVY_BIN" get SHARED > actual
cmp first-value actual || fail 'conflict changed the other machine value'

git --git-dir="$TEST_REMOTE" log --format=%B > history
cat offline.err conflict.err >> history
sed '/^$/d' first-value second-value > secret-patterns
if grep -F -f secret-patterns history > /dev/null; then
    fail 'sync logs or commit messages leaked a secret'
fi
for command in pull push sync; do
    if "$ENVY_BIN" "$command" extra > args.out 2> args.err; then
        fail 'sync command accepted extra arguments'
    fi
    grep "usage: envy $command" args.err > /dev/null || fail 'sync argument error is unclear'
done
