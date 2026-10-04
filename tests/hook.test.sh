#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-hook-passphrase
throwaway-hook-passphrase
RESPONSES
store=$XDG_DATA_HOME/envy/store
cat > "$HOME/expected-value" <<'VALUE'
quotes ' " and backslash \; $(touch "$HOME/injected") `false` $HOME
second line

VALUE
"$ENVY_BIN" set FIRST < "$HOME/expected-value"
printf '%s' 'second project credential' | "$ENVY_BIN" set SECOND
printf '' | "$ENVY_BIN" set EMPTY
cat > "$HOME/editor" <<'EDITOR'
#!/bin/sh
cp "$HOME/map-input" "$1"
EDITOR
chmod +x "$HOME/editor"
EDITOR=$HOME/editor
export EDITOR
cat > "$HOME/map-input" <<'MAP'
Shared=FIRST
OnlyOne=FIRST
Original=FIRST
Empty=EMPTY
UnsetBefore=EMPTY
MAP
"$ENVY_BIN" project edit first
printf 'Shared=SECOND\nOnlyTwo=SECOND\nOriginal=SECOND\n' > "$HOME/map-input"
"$ENVY_BIN" project edit second
mkdir -p "$HOME/first/deep/sub" "$HOME/second" "$HOME/outside" "$HOME/untrusted" "$HOME/broken"
(cd "$HOME/first" && "$ENVY_BIN" link --local first)
(cd "$HOME/second" && "$ENVY_BIN" link --local second)
printf 'RepoOnly=FIRST\n' > "$HOME/untrusted/.envy"
printf 'Good=FIRST\nBad=MISSING\nAlsoBad=OTHER_MISSING\n' > "$HOME/broken/.envy"
(cd "$HOME/broken" && "$ENVY_BIN" link --local first)
# Approval refuses invalid maps, so begin with a valid map and break it later.
printf 'Good=FIRST\n' > "$HOME/broken/.envy"
(cd "$HOME/broken" && "$ENVY_BIN" allow > /dev/null)

# Count actual decryptions without recording arguments or substituting crypto.
real_age=$(command -v age)
export real_age
mkdir "$HOME/bin"
ln -s "$ENVY_BIN" "$HOME/bin/envy"
cat > "$HOME/bin/age" <<'AGE'
#!/bin/sh
printf 'decrypt\n' >> "$HOME/age-calls"
exec "$real_age" "$@"
AGE
chmod +x "$HOME/bin/age"
PATH=$HOME/bin:$PATH
export PATH

cat > "$HOME/session" <<'SESSION'
set -u
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
notice_calls=0
notice() {
    notice_calls=$((notice_calls + 1))
    [ "$(wc -l < "$HOME/notice" | tr -d ' ')" = "$1" ] || fail "unexpected number of hook notices at check $notice_calls: expected $1 for $2"
    cat "$HOME/notice" >> "$HOME/all-notices"
    if [ "$1" != 0 ]; then
        grep -F "$2" "$HOME/notice" > /dev/null || fail 'missing hook notice'
    fi
}
cd "$HOME/outside" || exit 1
# Existing prompt callbacks remain registered, with exactly one envy callback.
if [ -n "${BASH_VERSION-}" ]; then
    PROMPT_COMMAND='printf existing >> "$HOME/existing-prompt"'
fi
eval "$(envy hook)"
eval "$(envy hook)"
if [ -n "${BASH_VERSION-}" ]; then
    eval "$PROMPT_COMMAND" 2> "$HOME/notice"
    [ "$(cat "$HOME/existing-prompt")" = existing ] || fail 'existing prompt callback was lost'
    case $PROMPT_COMMAND in *_envy_hook*_envy_hook*) fail 'duplicate bash hook' ;; esac
else
    # Run registered callbacks, as zsh does at a prompt; registration is public
    # shell state, rather than envy implementation state.
    for callback in "${precmd_functions[@]}"; do "$callback"; done 2> "$HOME/notice"
    [ "$(printf '%s\n' "${precmd_functions[@]}" | grep -c '^_envy_hook$')" = 1 ] || fail 'duplicate zsh hook'
fi
notice 0 ''
Original=$(cat "$HOME/expected-value"; printf '.')
Original=${Original%.}
export Original
Empty=''
# Enter, preserving a failing command's status and every byte in values.
cd "$HOME/first" || exit 1
(exit 37)
_envy_hook 2> "$HOME/notice"
[ "$?" = 37 ] || fail 'hook lost previous command status on load'
notice 1 'envy: loaded 5 vars'
sh -c 'printf "%s" "$Shared"' > "$HOME/observed"
cmp "$HOME/expected-value" "$HOME/observed" || fail 'ambient value changed bytes'
[ "${Empty+x}" = x ] && [ "$Empty" = '' ] || fail 'empty value did not load'
[ "${UnsetBefore+x}" = x ] && [ "$UnsetBefore" = '' ] || fail 'unset variable did not load empty value'
[ ! -e "$HOME/injected" ] || fail 'secret text was evaluated as code'
calls=$(wc -l < "$HOME/age-calls")
# A stationary prompt and a subdirectory transition are silent and do not decrypt.
_envy_hook 2> "$HOME/notice"
notice 0 ''
cd deep/sub || exit 1
(exit 23)
_envy_hook 2> "$HOME/notice"
[ "$?" = 23 ] || fail 'hook lost previous command status on fingerprint hit'
notice 0 ''
[ "$(wc -l < "$HOME/age-calls")" = "$calls" ] || fail 'subdirectory transition decrypted secrets'
# Swap projects, restoring originals before saving for the second project.
cd "$HOME/second" || exit 1
_envy_hook 2> "$HOME/notice"
notice 2 'envy: loaded 3 vars'
[ "$Shared" = 'second project credential' ] && [ "$Original" = "$Shared" ] || fail 'project swap failed'
[ "${OnlyOne+x}" != x ] && [ "${OnlyTwo+x}" = x ] || fail 'project swap retained old aliases'
[ "${Empty+x}" = x ] && [ "$Empty" = '' ] || fail 'pre-existing empty variable was not restored'
[ "${UnsetBefore+x}" != x ] || fail 'previously unset variable was not unset'
cd "$HOME/outside" || exit 1
(exit 19)
_envy_hook 2> "$HOME/notice"
[ "$?" = 19 ] || fail 'hook lost previous command status on unload'
notice 1 'envy: unloaded 3 vars'
sh -c 'printf "%s" "$Original"' > "$HOME/observed-original"
cmp "$HOME/expected-value" "$HOME/observed-original" || fail 'original did not survive two project loads'
[ "${Shared+x}" != x ] && [ "${OnlyTwo+x}" != x ] || fail 'leaving retained credentials'
# Unexported originals are visible only in the parent shell, and still restore.
unset Original
Original='private original'
cd "$HOME/first" || exit 1
_envy_hook 2> "$HOME/notice"
cd "$HOME/outside" || exit 1
_envy_hook 2> "$HOME/notice"
[ "$Original" = 'private original' ] || fail 'unexported original was lost'
# A CLI command invalidates the prompt's directory cache, including a failed one.
cd "$HOME/untrusted" || exit 1
_envy_hook 2> "$HOME/notice"
notice 1 'run envy allow'
[ "${RepoOnly+x}" != x ] || fail 'unapproved file loaded'
envy allow > /dev/null || fail 'approval failed'
_envy_hook 2> "$HOME/notice"
notice 1 'envy: loaded 1 vars'
[ "${RepoOnly+x}" = x ] || fail 'allow did not refresh at next prompt'
printf '# approval revoked\n' >> .envy
envy unknown > /dev/null 2> /dev/null
_envy_hook 2> "$HOME/notice"
[ "$?" = 1 ] || fail 'hook lost failed envy command status'
notice 2 'run envy allow'
[ "${RepoOnly+x}" != x ] || fail 'changed mapping retained credentials'
# Approve an invalid-file location while valid, then break its central layer.
cd "$HOME/broken" || exit 1
printf 'Good=FIRST\nBad=MISSING\nAlsoBad=OTHER_MISSING\n' > "$XDG_DATA_HOME/envy/store/projects/first/map"
_envy_hook 2> "$HOME/notice"
notice 1 'Bad: secret not found: MISSING'
[ "${Good+x}" != x ] && [ "${Shared+x}" != x ] || fail 'mapping error loaded a partial environment'
# No secrets may appear in any hook diagnostic.
cp "$HOME/notice" "$HOME/mapping-error"
# Repair the cached map and invoke a read command; retry at the same directory.
printf 'Shared=FIRST\n' > "$XDG_DATA_HOME/envy/store/projects/first/map"
envy version > /dev/null || fail 'version failed'
_envy_hook 2> "$HOME/notice"
notice 1 'envy: loaded 2 vars'
# A decryption failure must unload the old project and emit one safe error.
printf 'invalid ciphertext\n' > "$XDG_DATA_HOME/envy/store/secrets/SECOND.age"
cd "$HOME/second" || exit 1
_envy_hook 2> "$HOME/notice"
notice 2 'could not decrypt secret: SECOND'
[ "${Shared+x}" != x ] && [ "${Good+x}" != x ] || fail 'decryption error retained project environment'
# Verify missing-identity failures also unload, without ever prompting.
rm "$XDG_DATA_HOME/envy/identity"
cd "$HOME/outside" || exit 1
_envy_hook 2> "$HOME/notice"
notice 1 'run envy unlock'
# Global mappings apply outside projects and merge with central maps.
cp "$HOME/identity-backup" "$XDG_DATA_HOME/envy/identity"
cp "$HOME/second-ciphertext" "$XDG_DATA_HOME/envy/store/secrets/SECOND.age"
cp "$HOME/first-map" "$XDG_DATA_HOME/envy/store/projects/first/map"
printf 'GlobalOnly=FIRST\nShared=__literal__("global literal")\n' > "$HOME/map-input"
envy project edit --global || fail 'global edit failed'
_envy_hook 2> "$HOME/notice"
notice 1 'envy: loaded 2 vars'
[ "$Shared" = 'global literal' ] && [ "${GlobalOnly+x}" = x ] || fail 'global layer did not load outside project'
cd "$HOME/first" || exit 1
_envy_hook 2> "$HOME/notice"
notice 2 'envy: loaded 6 vars'
sh -c 'printf "%s" "$Shared"' > "$HOME/observed"
cmp "$HOME/expected-value" "$HOME/observed" || fail 'central layer did not override global'
cd "$HOME/untrusted" || exit 1
_envy_hook 2> "$HOME/notice"
notice 2 'run envy allow'
[ "${GlobalOnly+x}" != x ] && [ "${Shared+x}" != x ] || fail 'unapproved file retained globals'
# A readonly alias rolls back every assignment, with a fixed secret-free error.
ReadOnly='original readonly'
readonly ReadOnly
printf 'LoadedBefore=FIRST\nReadOnly=FIRST\n' > "$HOME/map-input"
envy project edit --global || fail 'readonly map edit failed'
cd "$HOME/outside" || exit 1
_envy_hook 2> "$HOME/notice"
notice 2 'envy: could not export project environment'
[ "$ReadOnly" = 'original readonly' ] && [ "${LoadedBefore+x}" != x ] || fail 'failed shell export did not roll back'
# Reset the global layer for the next shell using the same public CLI.
: > "$HOME/map-input"
envy project edit --global || fail 'global cleanup failed'
SESSION

cp "$store/projects/first/map" "$HOME/first-map"
cp "$store/secrets/SECOND.age" "$HOME/second-ciphertext"
cp "$XDG_DATA_HOME/envy/identity" "$HOME/identity-backup"
for shell in bash zsh; do
    command -v "$shell" > /dev/null || fail 'hook test requires bash and zsh'
    cp "$HOME/first-map" "$store/projects/first/map"
    cp "$HOME/second-ciphertext" "$store/secrets/SECOND.age"
    cp "$HOME/identity-backup" "$XDG_DATA_HOME/envy/identity"
    printf 'RepoOnly=FIRST\n' > "$HOME/untrusted/.envy"
    rm -f "$XDG_STATE_HOME/envy/allowed"
    (cd "$HOME/broken" && "$ENVY_BIN" allow > /dev/null)
    rm -f "$HOME/age-calls" "$HOME/existing-prompt" "$HOME/all-notices"
    case $shell in
        bash) set -- bash --noprofile --norc ;;
        zsh) set -- zsh -f ;;
    esac
    "$@" "$HOME/session" > "$HOME/session.out" 2> "$HOME/session.err" || {
        cat "$HOME/session.err" >&2
        fail 'shell hook session failed'
    }
    [ ! -s "$HOME/session.out" ] && [ ! -s "$HOME/session.err" ] || fail 'hook session emitted unexpected output'
    grep -F 'quotes' "$HOME/all-notices" > /dev/null && fail 'hook error disclosed a multiline value'
    grep -F 'second project credential' "$HOME/all-notices" > /dev/null && fail 'hook error disclosed a value'
done

for command in hook hook-env; do
    if "$ENVY_BIN" "$command" extra > "$HOME/args.out" 2> "$HOME/args.err"; then
        fail 'hook accepted extra arguments'
    fi
    [ ! -s "$HOME/args.out" ] && [ -s "$HOME/args.err" ] || fail 'hook argument error did not produce a safe diagnostic'
done
set -- "$TMPDIR"/envy-hook.*
for path do [ ! -e "$path" ] || fail 'hook left private temporary files'; done
