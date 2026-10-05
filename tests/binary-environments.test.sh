#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-binary-passphrase
throwaway-binary-passphrase
RESPONSES

cat > "$HOME/editor" <<'EDITOR'
#!/bin/sh
cp "$HOME/map-input" "$1"
EDITOR
chmod +x "$HOME/editor"
EDITOR=$HOME/editor
export EDITOR

# The original QA bytes, plus NULs at each boundary and inside readable text.
printf '\000\001\177\377\012' > "$HOME/binary"
printf '\000throwaway-binary-marker' > "$HOME/leading"
printf 'throwaway-binary\000marker\n' > "$HOME/middle"
printf 'throwaway-binary-marker\000' > "$HOME/trailing"
printf '\000' > "$HOME/nul-only"
cat > "$HOME/text" <<'VALUE'
throwaway 'quoted' "text" \ $HOME $(touch "$HOME/injected") `false`
second line

VALUE
printf '\001\177\200\376\377\n\n' >> "$HOME/text"
"$ENVY_BIN" set TEXT < "$HOME/text"
: > "$HOME/empty"
"$ENVY_BIN" set EMPTY < "$HOME/empty"
printf '\n\n' > "$HOME/newlines"
"$ENVY_BIN" set NEWLINES < "$HOME/newlines"

printf 'Before=TEXT\nRejected=QA_BINARY\nAfter=TEXT\n' > "$HOME/map-input"
# Create the referenced secret before validating the map.
"$ENVY_BIN" set QA_BINARY < "$HOME/binary"
"$ENVY_BIN" project edit binary
printf '%s\n' 'envy: secret contains a NUL byte: QA_BINARY; use envy get QA_BINARY' > "$HOME/expected-error"
for input in binary leading middle trailing nul-only; do
    "$ENVY_BIN" set QA_BINARY < "$HOME/$input" > "$HOME/set.out" 2> "$HOME/set.err"
    "$ENVY_BIN" get QA_BINARY > "$HOME/roundtrip" 2> "$HOME/get.err"
    cmp "$HOME/$input" "$HOME/roundtrip" || fail 'set/get changed binary bytes'
    if [ -s "$HOME/set.out" ] || [ -s "$HOME/set.err" ] || [ -s "$HOME/get.err" ]; then
        fail 'binary set/get emitted unsolicited output'
    fi
    for command in env run; do
        case $command in
            env) set -- env --project binary ;;
            run) set -- run --project binary -- touch "$HOME/child-ran" ;;
        esac
        if "$ENVY_BIN" "$@" > "$HOME/rejected.out" 2> "$HOME/rejected.err"; then
            fail "NUL-containing secret succeeded through $command"
        fi
        [ ! -s "$HOME/rejected.out" ] || fail 'failed binary mapping emitted partial exports'
        [ ! -e "$HOME/child-ran" ] || fail 'failed binary mapping started a child'
        cmp "$HOME/expected-error" "$HOME/rejected.err" || fail 'NUL diagnostic leaked bytes or omitted the secret name'
    done
done

# Preserve raw non-UTF-8 bytes, quotes and trailing newlines in every exporter.
printf 'Text=TEXT\nEmpty=EMPTY\nNewlines=NEWLINES\n' > "$HOME/map-input"
"$ENVY_BIN" project edit text
cat > "$HOME/observe" <<'OBSERVER'
#!/bin/sh
printf '%s' "$Text" > "$HOME/observed-text"
printf '%s' "$Empty" > "$HOME/observed-empty"
printf '%s' "$Newlines" > "$HOME/observed-newlines"
OBSERVER
check_observed() {
    for value in text empty newlines; do
        cmp "$HOME/$value" "$HOME/observed-$value" || fail "export changed $value bytes"
    done
    [ ! -e "$HOME/injected" ] || fail 'secret text executed shell syntax'
}
check_cleanup() {
    find "$XDG_DATA_HOME/envy" "$TMPDIR" -print | LC_ALL=C sort > "$HOME/paths-after"
    cmp "$HOME/paths-before" "$HOME/paths-after" || fail 'environment command left temporary files'
}
find "$XDG_DATA_HOME/envy" "$TMPDIR" -print | LC_ALL=C sort > "$HOME/paths-before"
check_cleanup

# Instrument the real crypto, asserting that decryption writes only to an
# owner-only file inside a new owner-only directory if it uses a plaintext file.
# Observe filesystem permissions without depending on temporary path names.
real_age=$(command -v age)
export real_age
mkdir "$HOME/bin"
ln -s "$ENVY_BIN" "$HOME/bin/envy"
cat > "$HOME/private-output.py" <<'PY'
import os
import stat
from pathlib import Path

output = os.fstat(1)
if stat.S_ISREG(output.st_mode):
    assert stat.S_IMODE(output.st_mode) == 0o600
    roots = [Path(os.environ['XDG_DATA_HOME']) / 'envy', Path(os.environ['TMPDIR'])]
    existing_paths = (Path(os.environ['HOME']) / 'paths-before').read_text().splitlines()
    found = False
    for root in roots:
        for directory, _, files in os.walk(root):
            for name in files:
                info = (Path(directory) / name).stat()
                if (info.st_dev, info.st_ino) == (output.st_dev, output.st_ino):
                    assert stat.S_IMODE(Path(directory).stat().st_mode) == 0o700
                    assert directory not in existing_paths
                    found = True
    assert found
else:
    assert stat.S_ISFIFO(output.st_mode)
PY
cat > "$HOME/bin/age" <<'AGE'
#!/bin/sh
if [ "${1-}" = -d ]; then
    python3 "$HOME/private-output.py" || exit 1
    printf 'decrypt\n' >> "$HOME/age-calls"
fi
exec "$real_age" "$@"
AGE
chmod +x "$HOME/bin/age"
PATH=$HOME/bin:$PATH
export PATH

"$ENVY_BIN" env --project text > "$HOME/evaluate"
cat "$HOME/observe" >> "$HOME/evaluate"
for shell in dash bash zsh; do
    "$shell" "$HOME/evaluate"
    check_observed
done
"$ENVY_BIN" run --project text -- sh "$HOME/observe"
check_observed
check_cleanup
# Cover failure cleanup with the private-file assertion active too.
if "$ENVY_BIN" env --project binary > "$HOME/rejected.out" 2> "$HOME/rejected.err"; then
    fail 'instrumented binary export succeeded'
fi
cmp "$HOME/expected-error" "$HOME/rejected.err" || fail 'private output probe failed'
check_cleanup

mkdir -p "$HOME/text-project/deep" "$HOME/binary-project" "$HOME/outside"
(cd "$HOME/text-project" && "$ENVY_BIN" link --local text)
(cd "$HOME/binary-project" && "$ENVY_BIN" link --local binary)
cat > "$HOME/session" <<'SESSION'
set -eu
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
cd "$HOME/outside"
Text=original
eval "$(envy hook)"
cd "$HOME/text-project"
_envy_hook 2> "$HOME/notice"
sh "$HOME/observe"
for value in text empty newlines; do
    cmp "$HOME/$value" "$HOME/observed-$value" || fail 'hook changed value bytes'
done
# Three winning aliases require three decryptions; a subdirectory fingerprint
# hit requires none, including none for the new validation.
[ "$(wc -l < "$HOME/age-calls" | tr -d ' ')" = 3 ] || fail 'hook added extra decryptions'
cd deep
_envy_hook 2> "$HOME/notice"
[ ! -s "$HOME/notice" ] || fail 'fingerprint hit emitted a notice'
[ "$(wc -l < "$HOME/age-calls" | tr -d ' ')" = 3 ] || fail 'fingerprint hit decrypted a value'
cd "$HOME/binary-project"
_envy_hook 2> "$HOME/notice"
# One value-free error line, followed by the usual unload notice.
cat "$HOME/expected-error" > "$HOME/expected-notice"
printf 'envy: unloaded 3 vars\n' >> "$HOME/expected-notice"
cmp "$HOME/expected-notice" "$HOME/notice" || fail 'hook did not report one safe NUL error'
[ "$Text" = original ] || fail 'hook failed to restore original variable'
[ "${Empty+x}" != x ] && [ "${Newlines+x}" != x ] || fail 'hook retained managed variables'
[ "${Before+x}" != x ] && [ "${Rejected+x}" != x ] && [ "${After+x}" != x ] || fail 'hook loaded partial binary mapping'
[ ! -e "$HOME/injected" ] || fail 'hook executed secret text'
# Retry with no managed variables: there must be exactly one error line.
envy version > /dev/null
_envy_hook 2> "$HOME/notice"
cmp "$HOME/expected-error" "$HOME/notice" || fail 'hook retry emitted more than one error'
SESSION
for shell in bash zsh; do
    : > "$HOME/age-calls"
    case $shell in
        bash) set -- bash --noprofile --norc ;;
        zsh) set -- zsh -f ;;
    esac
    "$@" "$HOME/session" > "$HOME/session.out" 2> "$HOME/session.err" || {
        cat "$HOME/session.err" >&2
        fail "binary hook session failed in $shell"
    }
    if [ -s "$HOME/session.out" ] || [ -s "$HOME/session.err" ]; then
        fail 'hook session emitted unsolicited output'
    fi
    check_cleanup
done
