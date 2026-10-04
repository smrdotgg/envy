#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

homes=$HOME
use_home() {
    HOME=$homes/$1
    XDG_DATA_HOME=$HOME/custom\ data
    XDG_CONFIG_HOME=$HOME/.config
    XDG_STATE_HOME=$HOME/.local/state
    XDG_CACHE_HOME=$HOME/.cache
    GIT_CONFIG_GLOBAL=$HOME/.gitconfig
    export HOME XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME GIT_CONFIG_GLOBAL
    mkdir -p "$HOME"
}

use_home first
python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-join-passphrase
throwaway-join-passphrase
RESPONSES
first_identity=$XDG_DATA_HOME/envy/identity
printf 'two-machine value with '\''quotes\nsecond line\n\n' > expected
"$ENVY_BIN" set SHARED < expected
revision=$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)

# Joining uses one passphrase prompt and creates no commit in the store.
use_home second
python3 "$TEST_ROOT/tests/pty-helper.py" --transcript join-terminal \
    -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-join-passphrase
RESPONSES
store=$XDG_DATA_HOME/envy/store
identity=$XDG_DATA_HOME/envy/identity
cmp "$first_identity" "$identity" || fail 'join did not recover the shared identity'
python3 - join-terminal "$identity" <<'PY'
import os
import re
import stat
import sys

with open(sys.argv[1], "rb") as transcript:
    output = transcript.read()
assert len(re.findall(rb"Enter passphrase[^\r\n]*?: ", output)) == 1
assert b"Confirm passphrase" not in output
assert b"throwaway-join-passphrase" not in output
assert stat.S_IMODE(os.stat(sys.argv[2]).st_mode) == 0o600
assert os.stat(sys.argv[2]).st_uid == os.getuid()
PY
assert_equal "$(git -C "$store" rev-parse HEAD)" "$revision" 'join changed the local revision'
assert_equal "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" "$revision" 'join pushed a commit'
assert_equal "$(git -C "$store" status --porcelain)" '' 'join dirtied the store'

# Reads and unlock work without a remote; get has no terminal and needs no prompt.
git -C "$store" remote set-url origin "$HOME/unreachable.git"
"$ENVY_BIN" get SHARED < /dev/null > actual 2> get.err
cmp expected actual || fail 'second machine could not read the first machine secret'
[ ! -s get.err ] || fail 'joined get produced an error'
rm "$identity"
python3 "$TEST_ROOT/tests/pty-helper.py" --transcript unlock-terminal \
    -- "$ENVY_BIN" unlock <<'RESPONSES'
throwaway-join-passphrase
RESPONSES
cmp "$first_identity" "$identity" || fail 'unlock did not re-create the local identity'
"$ENVY_BIN" get SHARED < /dev/null > actual
cmp expected actual || fail 'get failed after unlock'
python3 - unlock-terminal "$XDG_DATA_HOME/envy" <<'PY'
import pathlib
import re
import sys

output = pathlib.Path(sys.argv[1]).read_bytes()
assert len(re.findall(rb"Enter passphrase[^\r\n]*?: ", output)) == 1
assert sorted(p.name for p in pathlib.Path(sys.argv[2]).iterdir()) == ["identity", "store"]
PY
git -C "$store" remote set-url origin "$TEST_REMOTE"
"$ENVY_BIN" set SECOND < expected
assert_equal "$(git --git-dir="$TEST_REMOTE" log -1 --format=%s)" 'set SECOND' 'joined machine could not write'
revision=$(git -C "$store" rev-parse HEAD)

# Replacing the local key stops every existing secret command before any write.
age-keygen -o alternate-identity 2> /dev/null
cp alternate-identity "$identity"
cp "$store/secrets/SHARED.age" saved-secret.age
for command in set get ls; do
    case $command in
        ls) set -- ls ;;
        *) set -- "$command" SHARED ;;
    esac
    if "$ENVY_BIN" "$@" < expected > mismatch.out 2> mismatch.err; then
        fail 'mismatched local identity accepted'
    fi
    [ ! -s mismatch.out ] || fail 'mismatch printed secret output'
    grep 'run envy unlock' mismatch.err > /dev/null || fail 'mismatch lacks unlock advice'
    cmp saved-secret.age "$store/secrets/SHARED.age" || fail 'mismatch replaced ciphertext'
done
assert_equal "$(git -C "$store" rev-parse HEAD)" "$revision" 'mismatch committed a write'
assert_equal "$(git -C "$store" status --porcelain)" '' 'mismatch dirtied the store'

# Failed recovery must preserve the previous identity; a correct retry repairs it.
if python3 "$TEST_ROOT/tests/pty-helper.py" --transcript wrong-unlock-terminal \
    -- "$ENVY_BIN" unlock <<'RESPONSES'
wrong-throwaway-passphrase
RESPONSES
then
    fail 'unlock accepted a wrong passphrase'
fi
grep 'could not unlock identity' wrong-unlock-terminal > /dev/null || fail 'wrong passphrase not diagnosed'
cmp alternate-identity "$identity" || fail 'failed unlock replaced the old identity'
python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" unlock <<'RESPONSES'
throwaway-join-passphrase
RESPONSES
cmp "$first_identity" "$identity" || fail 'unlock did not repair a mismatched identity'

# Even a successfully decrypted identity must match the store recipient.
cp "$store/recipient" saved-recipient
age-keygen -y alternate-identity > "$store/recipient"
if python3 "$TEST_ROOT/tests/pty-helper.py" --transcript tampered-terminal \
    -- "$ENVY_BIN" unlock <<'RESPONSES'
throwaway-join-passphrase
RESPONSES
then
    fail 'unlock installed an identity that did not match the recipient'
fi
grep 'run envy unlock' tampered-terminal > /dev/null || fail 'recovered mismatch not diagnosed'
cmp "$first_identity" "$identity" || fail 'tampered store replaced the local identity'
mv saved-recipient "$store/recipient"
assert_equal "$(git -C "$store" status --porcelain)" '' 'unlock changed store contents'
assert_equal "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" "$revision" 'unlock pushed a commit'

# A failed join leaves neither a clone nor a partial plaintext identity.
use_home wrong
if python3 "$TEST_ROOT/tests/pty-helper.py" --transcript wrong-join-terminal \
    -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
wrong-throwaway-passphrase
RESPONSES
then
    fail 'join accepted a wrong passphrase'
fi
grep 'could not unlock identity' wrong-join-terminal > /dev/null || fail 'wrong join passphrase not diagnosed'
python3 - "$XDG_DATA_HOME/envy" <<'PY'
import pathlib
import sys
assert not list(pathlib.Path(sys.argv[1]).iterdir()), "failed join left local files"
PY
python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-join-passphrase
RESPONSES
"$ENVY_BIN" get SHARED < /dev/null > actual
cmp expected actual || fail 'retry after failed join did not work'

# A newer format is rejected by all secret commands and unlock before prompting.
use_home second
for format in 2 999999999999999999999999999999999999; do
    printf '%s\n' "$format" > "$store/format"
    for command in set get ls unlock; do
        case $command in
            ls|unlock) set -- "$command" ;;
            *) set -- "$command" SHARED ;;
        esac
        if "$ENVY_BIN" "$@" < expected > format.out 2> format.err; then
            fail 'newer format accepted'
        fi
        [ ! -s format.out ] || fail 'newer format produced stdout'
        grep 'update envy' format.err > /dev/null || fail 'newer format lacks update advice'
    done
done
cmp "$first_identity" "$identity" || fail 'format refusal replaced identity'
cmp saved-secret.age "$store/secrets/SHARED.age" || fail 'format refusal replaced ciphertext'

# Publish only a fixture format change; joining it must also refuse before a prompt.
git -C "$store" add format
git -C "$store" commit --quiet -m 'fixture newer format'
git -C "$store" push --quiet origin HEAD
use_home newer
if "$ENVY_BIN" init "$TEST_REMOTE" < /dev/null > newer.out 2> newer.err; then
    fail 'join accepted a newer format'
fi
grep 'update envy' newer.err > /dev/null || fail 'newer join lacks update advice'
python3 - "$XDG_DATA_HOME/envy" <<'PY'
import pathlib
import sys
assert not list(pathlib.Path(sys.argv[1]).iterdir()), "newer join left local files"
PY

if "$ENVY_BIN" unlock extra > args.out 2> args.err; then
    fail 'unlock accepted an argument'
fi
grep 'usage: envy unlock' args.err > /dev/null || fail 'unlock arguments not diagnosed'
if "$ENVY_BIN" unlock < /dev/null > missing.out 2> missing.err; then
    fail 'unlock accepted a missing store'
fi
grep 'store not initialized' missing.err > /dev/null || fail 'unlock missing store not diagnosed'
