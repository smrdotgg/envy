#!/bin/sh
# Harness helpers only; tests must exercise envy through its command line.

fixture_remote() (
    git -c init.defaultBranch=main init --bare --quiet "$1"
)

fail() (
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
)

assert_equal() (
    # Do not print the compared values: later tests may compare secrets.
    [ "$1" = "$2" ] || fail "$3"
)
