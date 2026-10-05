#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

printf 'a throwaway secret\nwith two lines\n\n' > original
python3 "$TEST_ROOT/tests/pty-helper.py" --transcript encrypt-terminal -- age -p -a -o encrypted.age original <<'RESPONSES'
throwaway-test-passphrase
throwaway-test-passphrase
RESPONSES
grep '^-----BEGIN AGE ENCRYPTED FILE-----' encrypted.age > /dev/null || fail 'missing armor'
python3 "$TEST_ROOT/tests/pty-helper.py" --transcript decrypt-terminal -- age -d -o decrypted encrypted.age <<'RESPONSES'
throwaway-test-passphrase
RESPONSES
cmp original decrypted || fail 'passphrase round trip changed the file'

if python3 "$TEST_ROOT/tests/pty-helper.py" --transcript wrong-terminal -- age -d -o wrong encrypted.age \
    > wrong.out 2> wrong.err <<'RESPONSES'
wrong-test-passphrase
RESPONSES
then
    fail 'wrong passphrase succeeded'
fi
if [ -s wrong.out ] || [ -s wrong.err ]; then
    fail 'helper exposed terminal output'
fi
python3 - <<'PY'
import pathlib
for name in ('encrypt-terminal', 'decrypt-terminal', 'wrong-terminal'):
    output = pathlib.Path(name).read_bytes()
    for value in (b'throwaway-test-passphrase', b'wrong-test-passphrase',
                  b'a throwaway secret', b'with two lines'):
        assert value not in output, 'age transcript exposed a value'
PY

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

# A prompt can be visible before its reader disables echo (as with age).
# Keep echo on after each hidden prompt and detect any premature input.
cat > delayed-reader.py <<'PY'
import os
import select
import termios

terminal = os.open('/dev/tty', os.O_RDWR)
original = termios.tcgetattr(terminal)
try:
    for prompt in (
        b'Enter passphrase: ', b'Confirm passphrase: ',
        b'Enter same passphrase again: ', b'Secret value: ',
    ):
        termios.tcsetattr(terminal, termios.TCSANOW, original)
        os.write(terminal, prompt)
        if select.select([terminal], [], [], 0.2)[0]:
            # Report only the ordering error; never print the response.
            os.write(terminal, b'input arrived before echo was disabled\n')
        hidden = termios.tcgetattr(terminal)
        hidden[3] &= ~termios.ECHO
        termios.tcsetattr(terminal, termios.TCSANOW, hidden)
        response = os.read(terminal, 4096)
        assert response == b'throwaway-delayed-response\n'
    termios.tcsetattr(terminal, termios.TCSANOW, original)
    # Ordinary confirmations still need a response while echo is enabled.
    os.write(terminal, b'Install age with brew? [y/N]: ')
    assert os.read(terminal, 4096) == b'n\n'
finally:
    termios.tcsetattr(terminal, termios.TCSANOW, original)
    os.close(terminal)
PY
python3 "$TEST_ROOT/tests/pty-helper.py" --transcript delayed-terminal -- \
    python3 delayed-reader.py <<'RESPONSES'
throwaway-delayed-response
throwaway-delayed-response
throwaway-delayed-response
throwaway-delayed-response
n
RESPONSES
python3 - <<'PY'
import pathlib
output = pathlib.Path('delayed-terminal').read_bytes()
assert b'input arrived before echo was disabled' not in output, 'helper typed before echo was disabled'
assert b'throwaway-delayed-response' not in output, 'hidden response appeared in transcript'
PY

# A broken password reader must time out without ever receiving hidden input.
cat > echoing-reader.py <<'PY'
import os
import select
terminal = os.open('/dev/tty', os.O_RDWR)
os.write(terminal, b'Enter passphrase: ')
if select.select([terminal], [], [], 10)[0]:
    os.write(terminal, b'input arrived with echo enabled\n')
    os.read(terminal, 4096)
PY
if python3 "$TEST_ROOT/tests/pty-helper.py" --timeout 0.3 --transcript echoing-terminal -- \
    python3 echoing-reader.py > echoing.out 2> echoing.err <<'RESPONSES'
throwaway-delayed-response
RESPONSES
then
    fail 'helper sent a password to an echoing reader'
fi
grep 'timed out' echoing.err > /dev/null || fail 'echoing password reader did not time out'
[ ! -s echoing.out ] || fail 'echoing reader exposed terminal output'
python3 - <<'PY'
import pathlib
output = pathlib.Path('echoing-terminal').read_bytes()
assert b'Enter passphrase: ' in output, 'echoing reader did not prompt'
assert b'input arrived with echo enabled' not in output
assert b'throwaway-delayed-response' not in output
PY
