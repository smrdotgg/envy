#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

"$ENVY_BIN" version > version.out 2> version.err
assert_equal "$(cat version.out)" 'envy 0.1.0-dev' 'version output'
[ ! -s version.err ] || fail 'version wrote to stderr'
dash "$ENVY_BIN" version > dash.out
cmp version.out dash.out || fail 'version differs under dash'

"$ENVY_BIN" help > help.out 2> help.err
[ ! -s help.err ] || fail 'help wrote to stderr'
for command in version help set get edit ls rm mv project link unlink allow run env \
    status check pull push sync init unlock hook config rekey doctor self-update uninstall; do
    grep -E "(^|[ ,|])$command([ ,|]|$)" help.out > /dev/null || fail 'help omitted a command'
done
"$ENVY_BIN" > default.out
cmp help.out default.out || fail 'no arguments should show help'

if "$ENVY_BIN" unknown-command > unknown.out 2> unknown.err; then
    fail 'unknown command succeeded'
fi
[ ! -s unknown.out ] || fail 'unknown command wrote to stdout'
grep 'envy: unknown command' unknown.err > /dev/null || fail 'missing unknown command error'

if "$ENVY_BIN" version unexpected > extra.out 2> extra.err; then
    fail 'unexpected argument succeeded'
fi
[ ! -s extra.out ] || fail 'unexpected argument wrote to stdout'
[ -s extra.err ] || fail 'unexpected argument had no error'
