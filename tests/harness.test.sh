#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

# Inspect the runner only through child environments, exit codes and git state.
HARNESS_OBSERVATIONS=$PWD/observations
export HARNESS_OBSERVATIONS
cat > 'first test.sh' <<'TEST'
#!/bin/sh
set -eu
[ -z "${GIT_AUTHOR_NAME+set}${GIT_AUTHOR_EMAIL+set}${GIT_COMMITTER_NAME+set}${GIT_COMMITTER_EMAIL+set}${GH_TOKEN+set}" ]
[ "$XDG_CONFIG_HOME" = "$HOME/.config" ]
[ "$XDG_DATA_HOME" = "$HOME/.local/share" ]
[ "$XDG_STATE_HOME" = "$HOME/.local/state" ]
[ "$XDG_CACHE_HOME" = "$HOME/.cache" ]
[ -d "$XDG_RUNTIME_DIR" ] && [ -d "$TMPDIR" ]
[ ! -e "$HOME/isolation-marker" ]
[ ! -e "$HOME/.gitconfig" ]
printf '%s\n' "$HOME" >> "$HARNESS_OBSERVATIONS"
touch "$HOME/isolation-marker"
[ "$(git --git-dir="$TEST_REMOTE" rev-parse --is-bare-repository)" = true ]
git clone --quiet "$TEST_REMOTE" clone 2> clone.err
git -C clone config user.name 'Fixture User'
git -C clone config user.email 'fixture@example.invalid'
printf '%s\n' fixture > clone/file
git -C clone add file
git -C clone commit --quiet -m 'test fixture'
git -C clone push --quiet origin HEAD
[ "$(git --git-dir="$TEST_REMOTE" show HEAD:file)" = fixture ]
TEST
cat > failure.sh <<'TEST'
#!/bin/sh
exit 7
TEST
cat > last.sh <<'TEST'
#!/bin/sh
set -eu
[ ! -e "$HOME/isolation-marker" ]
printf '%s\n' "$HOME" >> "$HARNESS_OBSERVATIONS"
[ "$(git --git-dir="$TEST_REMOTE" rev-parse --is-bare-repository)" = true ]
if git --git-dir="$TEST_REMOTE" rev-parse --verify HEAD > /dev/null 2>&1; then
    exit 1
fi
TEST

if GIT_AUTHOR_NAME=leaked GIT_AUTHOR_EMAIL=leaked GIT_COMMITTER_NAME=leaked \
    GIT_COMMITTER_EMAIL=leaked GH_TOKEN=leaked \
    dash "$TEST_ROOT/tests/run.sh" 'first test.sh' failure.sh last.sh > runner.out 2> runner.err; then
    fail 'runner did not propagate failure'
fi
[ ! -s runner.err ] || fail 'runner produced unexpected errors'
grep '^PASS first test.sh$' runner.out > /dev/null || fail 'first test did not pass'
grep '^FAIL failure.sh$' runner.out > /dev/null || fail 'failure not reported'
grep '^PASS last.sh$' runner.out > /dev/null || fail 'runner did not continue after failure'
grep '^3 tests, 1 failures$' runner.out > /dev/null || fail 'incorrect summary'
assert_equal "$(wc -l < "$HARNESS_OBSERVATIONS" | tr -d ' ')" 2 'missing home observations'
first_home=$(sed -n '1p' "$HARNESS_OBSERVATIONS")
last_home=$(sed -n '2p' "$HARNESS_OBSERVATIONS")
[ "$first_home" != "$last_home" ] || fail 'tests shared a home'
if [ -e "$first_home" ] || [ -e "$last_home" ]; then
    fail 'runner did not clean up'
fi

dash "$TEST_ROOT/tests/run.sh" last.sh > success.out
grep '^1 tests, 0 failures$' success.out > /dev/null || fail 'successful run failed'
if dash "$TEST_ROOT/tests/run.sh" nonexistent.test.sh > absent.out 2> absent.err; then
    fail 'missing test succeeded'
fi
grep '^FAIL nonexistent.test.sh$' absent.out > /dev/null || fail 'missing test not reported'

# A symlinked TMPDIR must provide the same physical paths and test results.
cat > canonical.sh <<'TEST'
#!/bin/sh
set -eu
for sandbox_dir in "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" \
    "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR" "$TMPDIR"; do
    [ "$sandbox_dir" = "$(CDPATH='' cd -- "$sandbox_dir" && pwd -P)" ]
done
remote_parent=${TEST_REMOTE%/*}
[ "$remote_parent" = "$(CDPATH='' cd -- "$remote_parent" && pwd -P)" ]
TEST
mkdir physical-temp
physical_temp=$(CDPATH='' cd physical-temp && pwd -P)
ln -s "$physical_temp" linked-temp
for temp_parent in "$physical_temp" "$PWD/linked-temp"; do
    TMPDIR=$temp_parent dash "$TEST_ROOT/tests/run.sh" canonical.sh \
        "$TEST_ROOT/tests/self-update.test.sh" > temp-runner.out 2> temp-runner.err || {
        cat temp-runner.err >&2
        fail 'runner failed under a physical or symlinked temp directory'
    }
    [ ! -s temp-runner.err ] || fail 'temp directory run emitted unexpected errors'
    grep '^2 tests, 0 failures$' temp-runner.out > /dev/null || fail 'temp directory run changed results'
    set -- "$physical_temp"/envy-test.*
    [ ! -e "$1" ] || fail 'runner left a sandbox under the temp directory'
done
