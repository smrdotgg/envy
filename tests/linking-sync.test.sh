#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-link-sync-passphrase
throwaway-link-sync-passphrase
RESPONSES

first_store=$XDG_DATA_HOME/envy/store
second_home=$HOME/second-machine
checkout=$HOME/checkout
git -c init.defaultBranch=main init --quiet "$checkout"
git -C "$checkout" remote add origin 'https://example.test/owner/repo.git'

second_machine() (
    HOME=$second_home
    XDG_DATA_HOME=$HOME/.local/share
    XDG_STATE_HOME=$HOME/.local/state
    XDG_CONFIG_HOME=$HOME/.config
    GIT_CONFIG_GLOBAL=$HOME/.gitconfig
    export HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CONFIG_HOME GIT_CONFIG_GLOBAL
    "$@"
)

# Join before either project exists, so the second machine's cache is stale.
second_machine python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-link-sync-passphrase
RESPONSES
second_store=$second_home/.local/share/envy/store
cd "$checkout"
"$ENVY_BIN" link first-project
remote_revision=$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)

# The retry rebase has no text conflict: the two remotes files are different.
if second_machine "$ENVY_BIN" link second-project > link.out 2> link.err; then
    fail 'a stale machine assigned a remote to a second project'
fi
grep 'duplicate project remotes; local commits retained' link.err > /dev/null || fail 'duplicate link retry did not explain recovery'
assert_equal "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" "$remote_revision" 'duplicate link reached the remote store'
assert_equal "$(git -C "$second_store" status --porcelain)" '' 'duplicate link retry left uncommitted changes'
assert_equal "$(git -C "$second_store" log -1 --format=%s)" 'link second-project' 'duplicate retry discarded its local commit'

# Explicit sync and push must also refuse the retained semantic conflict.
for command in check push sync; do
    if second_machine "$ENVY_BIN" "$command" > command.out 2> command.err; then
        fail 'duplicate remotes passed validation or sync'
    fi
    grep 'duplicate remote' command.err > /dev/null || fail 'duplicate remotes were not diagnosed'
    assert_equal "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" "$remote_revision" 'retry pushed duplicate remotes'
done

# Removing the conflicting project through the CLI makes sync usable again.
second_machine "$ENVY_BIN" project rm second-project
second_machine "$ENVY_BIN" check
"$ENVY_BIN" pull > /dev/null
"$ENVY_BIN" check
assert_equal "$(git -C "$first_store" rev-parse HEAD)" "$(git -C "$second_store" rev-parse HEAD)" 'machines did not converge after resolving duplicate links'
git --git-dir="$TEST_REMOTE" show HEAD:projects/first-project/remotes > remotes
printf 'example.test/owner/repo\n' > expected-remotes
cmp expected-remotes remotes || fail 'recovery lost the original remote link'
if git --git-dir="$TEST_REMOTE" cat-file -e HEAD:projects/second-project 2> /dev/null; then
    fail 'recovery kept the conflicting project'
fi
for state in "$XDG_STATE_HOME/envy" "$second_home/.local/state/envy"; do
    [ ! -e "$state/lock" ] || fail 'link retry left a lock'
done
for data in "$XDG_DATA_HOME/envy" "$second_home/.local/share/envy"; do
    for path in "$data"/.link.* "$data"/.remotes.*; do
        [ ! -e "$path" ] || fail 'link retry left temporary files'
    done
done
