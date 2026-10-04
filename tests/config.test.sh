#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

printf 'ambient=on\nquiet=off\nsync_interval=14400\n' > "$HOME/default-settings"
"$ENVY_BIN" config > "$HOME/settings"
cmp "$HOME/default-settings" "$HOME/settings" || fail 'wrong settings defaults before init'
[ ! -e "$XDG_CONFIG_HOME/envy/config" ] || fail 'showing defaults wrote settings'

# Settings do not require a store, and separate edits preserve each other.
"$ENVY_BIN" config ambient off
"$ENVY_BIN" config quiet on
"$ENVY_BIN" config > "$HOME/settings"
printf 'ambient=off\nquiet=on\nsync_interval=14400\n' > "$HOME/expected-settings"
cmp "$HOME/expected-settings" "$HOME/settings" || fail 'settings changes did not persist'
cp "$XDG_CONFIG_HOME/envy/config" "$HOME/config-backup"
for args in 'ambient' 'ambient yes' 'quiet 0' 'unknown on' 'ambient on extra'; do
    # Intentional splitting supplies CLI arguments from fixed test cases.
    if "$ENVY_BIN" config $args > "$HOME/args.out" 2> "$HOME/args.err"; then
        fail 'config accepted invalid arguments'
    fi
    [ ! -s "$HOME/args.out" ] && [ -s "$HOME/args.err" ] || fail 'invalid config lacked a diagnostic'
    cmp "$HOME/config-backup" "$XDG_CONFIG_HOME/envy/config" || fail 'invalid command changed settings'
done

# XDG config paths may contain spaces; falling back to HOME also works.
XDG_CONFIG_HOME="$HOME/config with spaces" "$ENVY_BIN" config quiet on
XDG_CONFIG_HOME="$HOME/config with spaces" "$ENVY_BIN" config > "$HOME/settings"
printf 'ambient=on\nquiet=on\nsync_interval=14400\n' > "$HOME/expected-settings"
cmp "$HOME/expected-settings" "$HOME/settings" || fail 'custom XDG config path ignored'
(unset XDG_CONFIG_HOME; "$ENVY_BIN" config > "$HOME/settings")
cmp "$HOME/config-backup" "$HOME/settings" || fail 'HOME config fallback ignored'

# Never evaluate a config file or echo its contents in errors.
printf 'quiet=$(touch "$HOME/config-injected")\n' > "$XDG_CONFIG_HOME/envy/config"
if "$ENVY_BIN" config > "$HOME/bad.out" 2> "$HOME/bad.err"; then
    fail 'config accepted shell code as a setting'
fi
[ ! -e "$HOME/config-injected" ] && [ ! -s "$HOME/bad.out" ] || fail 'config executed input'
grep -F 'touch' "$HOME/bad.err" > /dev/null && fail 'config diagnostic disclosed input'
cp "$HOME/config-backup" "$XDG_CONFIG_HOME/envy/config"

python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-config-passphrase
throwaway-config-passphrase
RESPONSES
store=$XDG_DATA_HOME/envy/store
printf 'throwaway ambient credential\n\n' > "$HOME/expected-value"
"$ENVY_BIN" set TOKEN < "$HOME/expected-value"
printf '' | "$ENVY_BIN" set EMPTY
cat > "$HOME/editor" <<'EDITOR'
#!/bin/sh
cp "$HOME/map-input" "$1"
EDITOR
chmod +x "$HOME/editor"
EDITOR=$HOME/editor
export EDITOR
printf 'Global=TOKEN\n' > "$HOME/map-input"
"$ENVY_BIN" project edit --global
printf 'Original=TOKEN\nProject=TOKEN\nEmpty=EMPTY\n' > "$HOME/map-input"
"$ENVY_BIN" project edit project
mkdir -p "$HOME/project/sub" "$HOME/outside" "$HOME/untrusted"
(cd "$HOME/project" && "$ENVY_BIN" link --local project)
printf 'Untrusted=TOKEN\n' > "$HOME/untrusted/.envy"

# Config writes change neither the store nor its local bare remote.
store_head=$(git -C "$store" rev-parse HEAD)
remote_head=$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)
"$ENVY_BIN" config ambient on
"$ENVY_BIN" config quiet off
assert_equal "$(git -C "$store" rev-parse HEAD)" "$store_head" 'config committed to store'
assert_equal "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" "$remote_head" 'config pushed to remote'
[ -z "$(git -C "$store" status --porcelain)" ] || fail 'config dirtied store'

# A second machine joins the same store and retains independent defaults.
mkdir "$HOME/second-home"
(
    HOME=$HOME/second-home
    XDG_DATA_HOME=$HOME/data
    XDG_CONFIG_HOME=$HOME/config
    XDG_STATE_HOME=$HOME/state
    export HOME XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME
    python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-config-passphrase
RESPONSES
    "$ENVY_BIN" config > "$HOME/settings"
)
cmp "$HOME/default-settings" "$HOME/second-home/settings" || fail 'settings synced to another machine'

# Count decryptions while always using real age.
real_age=$(command -v age)
export real_age
mkdir "$HOME/bin"
ln -s "$ENVY_BIN" "$HOME/bin/envy"
cat > "$HOME/bin/age" <<'AGE'
#!/bin/sh
printf 'age\n' >> "$HOME/age-calls"
exec "$real_age" "$@"
AGE
chmod +x "$HOME/bin/age"
PATH=$HOME/bin:$PATH
export PATH

cat > "$HOME/session" <<'SESSION'
set -u
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
notice() {
    [ "$(wc -l < "$HOME/notice" | tr -d ' ')" = "$1" ] || fail "unexpected notice count: $2"
    if [ "$1" != 0 ]; then
        grep -F "$2" "$HOME/notice" > /dev/null || fail 'missing diagnostic'
    fi
    cat "$HOME/notice" >> "$HOME/notices"
}
loaded() {
    sh -c 'printf "%s" "$Project"' > "$HOME/observed"
    cmp "$HOME/expected-value" "$HOME/observed" || fail 'wrong loaded credential'
    [ "${Global+x}" = x ] && [ "${Empty+x}" = x ] && [ "$Empty" = '' ] || fail 'missing ambient layer'
}
unloaded() {
    [ "${Project+x}" != x ] && [ "${Global+x}" != x ] && [ "${Empty+x}" != x ] || fail 'ambient off retained variables'
    [ "$Original" = before ] || fail 'ambient off did not restore original'
}
Original=before
cd "$HOME/project" || exit 1
eval "$(envy hook)"
_envy_hook 2> "$HOME/notice"
notice 1 'loaded 4 vars'
loaded
calls=$(wc -l < "$HOME/age-calls")

# Config commands refresh at the same directory and preserve previous status.
envy config ambient off || fail 'ambient off failed'
(exit 27)
_envy_hook 2> "$HOME/notice"
[ "$?" = 27 ] || fail 'ambient off lost previous command status'
notice 1 'unloaded 4 vars'
unloaded
cd sub || exit 1
_envy_hook 2> "$HOME/notice"
notice 0 ''
[ "$(wc -l < "$HOME/age-calls")" = "$calls" ] || fail 'ambient off decrypted secrets'

# Explicit commands keep working with both machine and shell ambient off.
export ENVY_AMBIENT=0
envy run -- sh -c 'printf "%s" "$Project"' > "$HOME/observed" || fail 'run failed with ambient off'
cmp "$HOME/expected-value" "$HOME/observed" || fail 'ambient off changed run environment'
envy env > "$HOME/exports" || fail 'env failed with ambient off'
sh -c 'eval "$(cat "$HOME/exports")"; printf "%s" "$Project"' > "$HOME/observed"
cmp "$HOME/expected-value" "$HOME/observed" || fail 'ambient off changed env output'
_envy_hook 2> "$HOME/notice"
notice 0 ''
unloaded

# Override changes refresh a stationary shell. No export is needed in the shim.
ENVY_AMBIENT=1
_envy_hook 2> "$HOME/notice"
notice 1 'loaded 4 vars'
loaded
ENVY_AMBIENT=0
_envy_hook 2> "$HOME/notice"
notice 1 'unloaded 4 vars'
unloaded
envy config ambient on || fail 'ambient on failed'
_envy_hook 2> "$HOME/notice"
notice 0 ''
unloaded
unset ENVY_AMBIENT
_envy_hook 2> "$HOME/notice"
notice 1 'loaded 4 vars'
loaded

# Quiet changes take effect on fingerprint hits and silence both notice kinds.
envy config quiet on || fail 'quiet on failed'
_envy_hook 2> "$HOME/notice"
notice 0 ''
loaded
envy config ambient off || fail 'ambient off failed'
_envy_hook 2> "$HOME/notice"
notice 0 ''
unloaded
envy config ambient on || fail 'ambient on failed'
_envy_hook 2> "$HOME/notice"
notice 0 ''
loaded
cd "$HOME/untrusted" || exit 1
_envy_hook 2> "$HOME/notice"
notice 1 'run envy allow'
unloaded
cd "$HOME/project" || exit 1
_envy_hook 2> "$HOME/notice"
notice 0 ''
loaded
cp "$XDG_DATA_HOME/envy/store/projects/project/map" "$HOME/map-backup"
printf 'Project=MISSING\n' > "$XDG_DATA_HOME/envy/store/projects/project/map"
envy version > /dev/null
_envy_hook 2> "$HOME/notice"
notice 1 'secret not found: MISSING'
unloaded
cp "$HOME/map-backup" "$XDG_DATA_HOME/envy/store/projects/project/map"
envy version > /dev/null
_envy_hook 2> "$HOME/notice"
notice 0 ''
loaded

# Even shell export failures remain visible in quiet mode.
readonly Original
envy config ambient off || fail 'ambient off failed'
_envy_hook 2> "$HOME/notice"
notice 0 ''
envy config ambient on || fail 'ambient on failed'
_envy_hook 2> "$HOME/notice"
notice 1 'could not export project environment'

# Disabled ambient does not require an identity or trust at the current path.
envy config quiet off || fail 'quiet off failed'
envy config ambient off || fail 'ambient off failed'
mv "$XDG_DATA_HOME/envy/identity" "$HOME/identity-backup"
cd "$HOME/untrusted" || exit 1
_envy_hook 2> "$HOME/notice"
notice 0 ''
envy config quiet on || fail 'quiet on failed'
envy config ambient on || fail 'ambient on failed'
_envy_hook 2> "$HOME/notice"
notice 1 'run envy unlock'
mv "$HOME/identity-backup" "$XDG_DATA_HOME/envy/identity"
SESSION

for shell in bash zsh; do
    "$ENVY_BIN" config ambient on
    "$ENVY_BIN" config quiet off
    : > "$HOME/age-calls"
    : > "$HOME/notices"
    case $shell in
        bash) set -- bash --noprofile --norc ;;
        zsh) set -- zsh -f ;;
    esac
    "$@" "$HOME/session" > "$HOME/session.out" 2> "$HOME/session.err" || {
        cat "$HOME/session.err" >&2
        fail 'config hook session failed'
    }
    [ ! -s "$HOME/session.out" ] && [ ! -s "$HOME/session.err" ] || fail 'session emitted unexpected output'
    grep -F 'throwaway ambient credential' "$HOME/notices" > /dev/null && fail 'notice disclosed secret'
done

assert_equal "$(git -C "$store" rev-parse HEAD)" "$store_head" 'hook settings committed to store'
assert_equal "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" "$remote_head" 'hook settings pushed to remote'
[ -z "$(git -C "$store" status --porcelain)" ] || fail 'hook settings dirtied store'
set -- "$XDG_CONFIG_HOME/envy"/.config.* "$TMPDIR"/envy-hook.*
for path do [ ! -e "$path" ] || fail 'settings or hook left temporary files'; done
