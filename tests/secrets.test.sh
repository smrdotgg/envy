#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-secret-test-passphrase
throwaway-secret-test-passphrase
RESPONSES
store=$XDG_DATA_HOME/envy/store
identity=$XDG_DATA_HOME/envy/identity

# Compare files, preserving all bytes rather than using command substitution.
printf 'throwaway value with quotes: '\'' " and \\ $ `\nsecond line\n\n' > multiline
printf 'no trailing newline' > single
: > empty
printf '\n\n\n' > newlines
printf ' leading and trailing spaces \n' > spaces
count=1
for pair in 'MULTILINE multiline' '_SINGLE single' 'EMPTY empty' 'NEWLINES newlines' 'SPACES spaces'; do
    name=${pair%% *}
    input=${pair#* }
    "$ENVY_BIN" set "$name" < "$input" > set.out 2> set.err
    if [ -s set.out ] || [ -s set.err ]; then
        fail 'successful piped set produced output'
    fi
    "$ENVY_BIN" get "$name" > actual 2> get.err
    cmp "$input" actual || fail 'secret round trip changed bytes'
    [ ! -s get.err ] || fail 'successful get produced an error'
    count=$((count + 1))
    assert_equal "$(git --git-dir="$TEST_REMOTE" rev-list --count HEAD)" "$count" 'write did not make one pushed commit'
    assert_equal "$(git --git-dir="$TEST_REMOTE" log -1 --format=%s)" "set $name" 'set commit message'
    assert_equal "$(git -C "$store" rev-parse HEAD)" "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" 'write was not pushed'
    git --git-dir="$TEST_REMOTE" show "HEAD:secrets/$name.age" > remote-secret.age
    grep '^-----BEGIN AGE ENCRYPTED FILE-----' remote-secret.age > /dev/null || fail 'secret is not armored'
    age -d -i "$identity" remote-secret.age > remote-value 2> /dev/null
    cmp "$input" remote-value || fail 'remote secret differs'
    assert_equal "$(git -C "$store" status --porcelain)" '' 'write left uncommitted changes'
done
"$ENVY_BIN" set MULTILINE < single
"$ENVY_BIN" get MULTILINE > replaced
cmp single replaced || fail 'overwriting secret did not replace the value'
count=$((count + 1))
assert_equal "$(git --git-dir="$TEST_REMOTE" rev-list --count HEAD)" "$count" 'replacement did not make one commit'

"$ENVY_BIN" ls > names
printf 'EMPTY\nMULTILINE\nNEWLINES\nSPACES\n_SINGLE\n' > expected-names
LC_ALL=C sort names > sorted-names
cmp expected-names sorted-names || fail 'ls returned incorrect names'
# ls needs no value decryption: even invalid ciphertext still lists by name.
cp "$store/secrets/EMPTY.age" saved-empty.age
printf 'not ciphertext\n' > "$store/secrets/EMPTY.age"
"$ENVY_BIN" ls > corrupt-list
cmp names corrupt-list || fail 'ls tried to decrypt values'
if "$ENVY_BIN" get EMPTY > corrupt.out 2> corrupt.err; then
    fail 'get accepted corrupt ciphertext'
fi
mv saved-empty.age "$store/secrets/EMPTY.age"
if "$ENVY_BIN" get MISSING > missing.out 2> missing.err; then
    fail 'get succeeded for a missing secret'
fi
[ ! -s missing.out ] || fail 'missing secret produced stdout'
grep 'secret not found: MISSING' missing.err > /dev/null || fail 'missing secret error is unclear'

revision=$(git -C "$store" rev-parse HEAD)
for name in '' lowercase Mixed 1DIGIT 'WITH-DASH' 'WITH SPACE' '../ESCAPE' 'A/B' 'A=B' 'A
B'; do
    for command in set get; do
        if "$ENVY_BIN" "$command" "$name" < single > invalid.out 2> invalid.err; then
            fail 'invalid secret name accepted'
        fi
        [ ! -s invalid.out ] || fail 'invalid name wrote stdout'
        grep 'invalid secret name' invalid.err > /dev/null || fail 'invalid name not diagnosed'
    done
done
for command in set get ls; do
    if "$ENVY_BIN" "$command" SPACES extra < single > args.out 2> args.err; then
        fail 'extra arguments accepted'
    fi
    grep 'usage:' args.err > /dev/null || fail 'extra arguments not diagnosed'
done
for command in set get; do
    if "$ENVY_BIN" "$command" > args.out 2> args.err; then
        fail 'missing name accepted'
    fi
done
assert_equal "$(git -C "$store" rev-parse HEAD)" "$revision" 'rejected command changed history'
assert_equal "$(git -C "$store" status --porcelain)" '' 'rejected command changed store'

# Drive the hidden terminal prompt, and observe restoration in the caller.
printf '%s\n' 'hidden-throwaway-value with \ spaces' > terminal-response
printf '%s' 'hidden-throwaway-value with \ spaces' > terminal-expected
cat > terminal-set.sh <<'SH'
#!/bin/sh
set -eu
stty -g > tty-before
"$ENVY_BIN" set TERMINAL
stty -g > tty-after
SH
python3 "$TEST_ROOT/tests/pty-helper.py" --transcript set-terminal -- sh terminal-set.sh < terminal-response
cmp tty-before tty-after || fail 'set did not restore terminal settings'
grep 'Secret value: ' set-terminal > /dev/null || fail 'set did not prompt on terminal'
if grep -F -f terminal-response set-terminal > /dev/null; then
    fail 'terminal echoed the secret'
fi
"$ENVY_BIN" get TERMINAL > terminal-actual
cmp terminal-expected terminal-actual || fail 'hidden prompt changed the value'
count=$((count + 1))
assert_equal "$(git --git-dir="$TEST_REMOTE" rev-list --count HEAD)" "$count" 'terminal write did not commit and push once'

# Logs and git history must contain actions and names, never secret values.
git --git-dir="$TEST_REMOTE" log --format=%B > history
if grep -F -f terminal-response history > /dev/null || grep -F -f single history > /dev/null; then
    fail 'commit message contains a secret value'
fi

# A changed recipient must stop every use without creating a commit.
cp "$store/recipient" saved-recipient
age-keygen -o alternate-identity 2> /dev/null
age-keygen -y alternate-identity > "$store/recipient"
revision=$(git -C "$store" rev-parse HEAD)
for command in set get ls; do
    case $command in
        ls) set -- ls ;;
        *) set -- "$command" SPACES ;;
    esac
    if "$ENVY_BIN" "$@" < single > mismatch.out 2> mismatch.err; then
        fail 'recipient mismatch accepted'
    fi
    [ ! -s mismatch.out ] || fail 'recipient mismatch produced stdout'
    grep 'run envy unlock' mismatch.err > /dev/null || fail 'recipient mismatch lacks unlock advice'
done
assert_equal "$(git -C "$store" rev-parse HEAD)" "$revision" 'recipient mismatch created a commit'
mv saved-recipient "$store/recipient"
mv "$identity" saved-identity
if "$ENVY_BIN" get SPACES > no-identity.out 2> no-identity.err; then
    fail 'missing identity accepted'
fi
grep 'local identity missing; run envy unlock' no-identity.err > /dev/null || fail 'missing identity error is unclear'
mv saved-identity "$identity"
printf '2\n' > "$store/format"
if "$ENVY_BIN" set SPACES < single > format.out 2> format.err; then
    fail 'newer store format accepted'
fi
grep 'unsupported store format' format.err > /dev/null || fail 'unsupported format error is unclear'
