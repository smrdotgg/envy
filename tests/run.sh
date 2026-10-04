#!/bin/sh
set -eu

TEST_ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd -P)
export TEST_ROOT

if [ "$#" -eq 0 ]; then
    set -- "$TEST_ROOT"/tests/*.test.sh
fi

run_test() (
    test_file=$1
    test_sandbox=$(mktemp -d "${TMPDIR:-/tmp}/envy-test.XXXXXX") || exit 1
    trap 'rm -rf "$test_sandbox"' 0
    trap 'exit 1' HUP INT TERM
    umask 077

    # Never inherit the engineer's git identity or credentials into fixtures.
    unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GH_TOKEN
    unset ENVY_AMBIENT
    unset ENVY_INSTALL_SOURCE
    HOME=$test_sandbox/home
    XDG_CONFIG_HOME=$HOME/.config
    XDG_DATA_HOME=$HOME/.local/share
    XDG_STATE_HOME=$HOME/.local/state
    XDG_CACHE_HOME=$HOME/.cache
    XDG_RUNTIME_DIR=$test_sandbox/runtime
    TMPDIR=$test_sandbox/tmp
    GIT_CONFIG_NOSYSTEM=1
    GIT_CONFIG_GLOBAL=$HOME/.gitconfig
    ENVY_BIN=$TEST_ROOT/envy
    TEST_REMOTE=$test_sandbox/remote.git
    export HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
    export XDG_RUNTIME_DIR TMPDIR GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL ENVY_BIN TEST_REMOTE
    mkdir -p "$HOME/work" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" \
        "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR" "$TMPDIR" || exit 1
    . "$TEST_ROOT/tests/fixtures.sh"
    fixture_remote "$TEST_REMOTE" || exit 1
    cd "$HOME/work" || exit 1
    dash "$test_file"
)

test_failures=0
test_total=0
for test_path do
    case $test_path in
        /*) ;;
        *) test_path=$PWD/$test_path ;;
    esac
    test_total=$((test_total + 1))
    if [ -f "$test_path" ] && run_test "$test_path"; then
        printf 'PASS %s\n' "${test_path##*/}"
    else
        printf 'FAIL %s\n' "${test_path##*/}"
        test_failures=$((test_failures + 1))
    fi
done
printf '%s tests, %s failures\n' "$test_total" "$test_failures"
[ "$test_failures" -eq 0 ]
