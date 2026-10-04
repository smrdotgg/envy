#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

printf 'a throwaway secret\nwith two lines\n\n' > original
python3 "$TEST_ROOT/tests/pty-helper.py" -- age -p -a -o encrypted.age original <<'RESPONSES'
throwaway-test-passphrase
throwaway-test-passphrase
RESPONSES
grep '^-----BEGIN AGE ENCRYPTED FILE-----' encrypted.age > /dev/null || fail 'missing armor'
python3 "$TEST_ROOT/tests/pty-helper.py" -- age -d -o decrypted encrypted.age <<'RESPONSES'
throwaway-test-passphrase
RESPONSES
cmp original decrypted || fail 'passphrase round trip changed the file'

if python3 "$TEST_ROOT/tests/pty-helper.py" -- age -d -o wrong encrypted.age \
    > wrong.out 2> wrong.err <<'RESPONSES'
wrong-test-passphrase
RESPONSES
then
    fail 'wrong passphrase succeeded'
fi
if [ -s wrong.out ] || [ -s wrong.err ]; then
    fail 'helper exposed terminal output'
fi

if python3 "$TEST_ROOT/tests/pty-helper.py" -- age -d encrypted.age \
    < /dev/null > missing.out 2> missing.err; then
    fail 'missing prompt response succeeded'
fi
grep 'no response supplied' missing.err > /dev/null || fail 'missing response was not diagnosed'

if python3 "$TEST_ROOT/tests/pty-helper.py" --timeout 0.2 -- sleep 10 \
    < /dev/null > timeout.out 2> timeout.err; then
    fail 'unresponsive command succeeded'
fi
grep 'timed out' timeout.err > /dev/null || fail 'timeout was not diagnosed'
