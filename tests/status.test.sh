#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-status-passphrase
throwaway-status-passphrase
RESPONSES
store=$XDG_DATA_HOME/envy/store
printf 'throwaway status secret\nsecond line\n\n' > "$HOME/value"
"$ENVY_BIN" set TOKEN < "$HOME/value"
cat > "$HOME/editor" <<'EDITOR'
#!/bin/sh
cp "$HOME/map-input" "$1"
EDITOR
chmod +x "$HOME/editor"
EDITOR=$HOME/editor
export EDITOR
cat > "$HOME/map-input" <<'MAP'
Shared=TOKEN
GlobalOnly=TOKEN
Literal=__literal__("private literal text")
Repeated=TOKEN
Repeated=__literal__("private overwritten literal")
MAP
"$ENVY_BIN" project edit --global
printf 'Shared=TOKEN\nCentralOnly=TOKEN\n' > "$HOME/map-input"
"$ENVY_BIN" project edit app
printf 'LocalOnly=TOKEN\n' > "$HOME/map-input"
"$ENVY_BIN" project edit override

status_ok() {
    "$ENVY_BIN" status > "$HOME/status.out" 2> "$HOME/status.err" || {
        cat "$HOME/status.err" >&2
        fail 'valid status failed'
    }
    [ ! -s "$HOME/status.err" ] || fail 'valid status emitted errors'
    cat "$HOME/status.out" "$HOME/status.err" >> "$HOME/status-log"
}
status_bad() {
    if "$ENVY_BIN" status > "$HOME/status.out" 2> "$HOME/status.err"; then
        fail 'status succeeded with blocked layers or identity'
    fi
    cat "$HOME/status.out" "$HOME/status.err" >> "$HOME/status-log"
}
shows() {
    grep -Fx "$1" "$HOME/status.out" > /dev/null || fail 'status omitted expected state or provenance'
}
blocked() {
    shows 'Aliases: none (layers blocked; nothing can be loaded)'
    grep -F ' <- ' "$HOME/status.out" > /dev/null && fail 'blocked status showed a partial environment'
    return 0
}

# Outside projects, global aliases still have accurate file/line provenance.
status_ok
shows 'Project root: none'
shows 'Project: none (match: no project)'
shows "Layer global: present ($store/global)"
shows 'Layer central project: absent (no matched project)'
shows "Layer in-project: absent ($HOME/work/.envy)"
shows "  Shared <- $store/global:1 (secret)"
shows "  Repeated <- $store/global:5 (literal)"
shows 'Sync (cached upstream): ahead 0, behind 0'
shows "Last fetch: $(cat "$XDG_STATE_HOME/envy/last-fetch") (epoch seconds)"
shows 'Identity: matches store'

# Cached remote matches resolve from subdirectories and worktrees.
app=$HOME/app
git -c init.defaultBranch=main init --quiet "$app"
printf 'checkout\n' > "$app/tracked"
git -C "$app" add tracked
git -C "$app" -c user.name=fixture -c user.email=fixture@localhost commit --quiet -m fixture
git -C "$app" remote add origin "$HOME/code.git"
mkdir -p "$app/deep/sub"
cd "$app"
"$ENVY_BIN" link app
cd deep/sub
status_ok
shows "Project root: $app"
shows 'Project: app (match: remote)'
shows "Layer central project: present ($store/projects/app/map)"
shows "  Shared <- $store/projects/app/map:1 (secret)"
shows "  GlobalOnly <- $store/global:2 (secret)"
git -C "$app" worktree add --quiet -b status-worktree "$HOME/worktree"
cd "$HOME/worktree"
status_ok
shows "Project root: $HOME/worktree"
shows 'Project: app (match: remote)'

# A local link wins over the same checkout's remote match.
cd "$app"
"$ENVY_BIN" link --local override
cd deep/sub
status_ok
shows "Project root: $app"
shows 'Project: override (match: local link)'
shows "  LocalOnly <- $store/projects/override/map:1 (secret)"
"$ENVY_BIN" unlink

# Trust blocks every layer; approval restores last-wins provenance, including
# repeated aliases and changes between literal and secret assignments.
cat > "$app/.envy" <<'MAP'
Shared=__literal__("private project literal")
Shared=TOKEN
ProjectOnly=TOKEN
Literal=TOKEN
MAP
status_bad
shows "Layer in-project: unapproved ($app/.envy)"
blocked
grep -F 'run envy allow' "$HOME/status.err" > /dev/null || fail 'missing approval guidance'
"$ENVY_BIN" allow > /dev/null
status_ok
shows "Layer in-project: present ($app/.envy)"
shows "  Shared <- $app/.envy:2 (secret)"
shows "  Literal <- $app/.envy:4 (secret)"
shows "  CentralOnly <- $store/projects/app/map:2 (secret)"
assert_equal "$(grep -c '  Shared <- ' "$HOME/status.out")" 1 'status emitted overwritten aliases'
printf '# changed\n' >> "$app/.envy"
status_bad
shows "Layer in-project: unapproved ($app/.envy)"
blocked
"$ENVY_BIN" allow > /dev/null

# Each layer is validated independently, and malformed input is never echoed.
for mapping in "$store/global" "$store/projects/app/map" "$app/.envy"; do
    cp "$mapping" "$HOME/saved-map"
    printf 'Good=TOKEN\nBad=__literal__("private malformed text"oops)\nMissing=NO_SUCH_SECRET\n' > "$mapping"
    status_bad
    case $mapping in
        "$store/global") label=global ;;
        "$store/projects/app/map") label='central project' ;;
        *) label=in-project ;;
    esac
    shows "Layer $label: invalid ($mapping)"
    blocked
    grep -F "$mapping:2: Bad:" "$HOME/status.err" > /dev/null || fail 'missing syntax location'
    grep -F "$mapping:3: Missing: secret not found: NO_SUCH_SECRET" "$HOME/status.err" > /dev/null || fail 'missing reference location'
    grep -F 'private malformed text' "$HOME/status.out" "$HOME/status.err" > /dev/null && fail 'status exposed malformed mapping text'
    shows 'Identity: matches store'
    mv "$HOME/saved-map" "$mapping"
done

# Invalid file types and missing central mappings are visible and block aliases.
mv "$app/.envy" "$HOME/saved-inproject"
mkdir "$app/.envy"
status_bad
shows "Layer in-project: invalid ($app/.envy)"
blocked
rmdir "$app/.envy"
mv "$HOME/saved-inproject" "$app/.envy"
mv "$store/projects/app/map" "$HOME/saved-map"
status_bad
shows "Layer central project: invalid ($store/projects/app/map)"
blocked
mv "$HOME/saved-map" "$store/projects/app/map"

# File-only projects and non-git local links use the nearest ancestor root.
mkdir -p "$HOME/file only/deep" "$HOME/scratch/deep" "$HOME/outside"
printf 'FileOnly=TOKEN\n' > "$HOME/file only/.envy"
cd "$HOME/file only/deep"
status_bad
shows "Project root: $HOME/file only"
shows 'Project: none (match: in-project file only)'
"$ENVY_BIN" allow > /dev/null
status_ok
shows "  FileOnly <- $HOME/file only/.envy:1 (secret)"
cd "$HOME/scratch"
"$ENVY_BIN" link --local override
cd deep
status_ok
shows "Project root: $HOME/scratch"
shows 'Project: override (match: local link)'
cd "$HOME/outside"
mv "$store/global" "$HOME/saved-global"
status_ok
shows "Layer global: absent ($store/global)"
shows '  none'
mv "$HOME/saved-global" "$store/global"

# Effective ambient settings include the inherited shell override.
"$ENVY_BIN" config ambient off
status_ok
shows 'Ambient: off (machine: off)'
ENVY_AMBIENT=1 "$ENVY_BIN" status > "$HOME/status.out"
shows 'Ambient: on (machine: off)'
"$ENVY_BIN" config ambient on
ENVY_AMBIENT=0 "$ENVY_BIN" status > "$HOME/status.out"
shows 'Ambient: off (machine: on)'
ENVY_AMBIENT=invalid status_bad
shows 'Ambient: invalid (machine: on)'
grep -F 'ENVY_AMBIENT must be 0 or 1' "$HOME/status.err" > /dev/null || fail 'invalid ambient override went undiagnosed'

# Identity problems do not hide the layer/sync report or prompt for a passphrase.
mv "$XDG_DATA_HOME/envy/identity" "$HOME/saved-identity"
status_bad
shows 'Identity: unavailable or does not match store; run envy unlock'
shows "Layer global: present ($store/global)"
age-keygen -o "$XDG_DATA_HOME/envy/identity" > /dev/null 2>&1
status_bad
grep -F 'store public key does not match local identity' "$HOME/status.err" > /dev/null || fail 'identity mismatch went undiagnosed'
printf 'not an identity\n' > "$XDG_DATA_HOME/envy/identity"
status_bad
grep -F 'cannot read local identity' "$HOME/status.err" > /dev/null || fail 'invalid identity went undiagnosed'
mv "$HOME/saved-identity" "$XDG_DATA_HOME/envy/identity"

# Ahead/behind describe cached refs, so remote changes alone are invisible.
git clone --quiet "$TEST_REMOTE" "$HOME/peer"
printf 'peer change\n' > "$HOME/peer/peer-change"
git -C "$HOME/peer" add peer-change
git -C "$HOME/peer" -c user.name=fixture -c user.email=fixture@localhost commit --quiet -m 'peer change'
git -C "$HOME/peer" push --quiet origin main
status_ok
shows 'Sync (cached upstream): ahead 0, behind 0'
git -C "$store" fetch --quiet origin
status_ok
shows 'Sync (cached upstream): ahead 0, behind 1'
git -C "$store" remote set-url origin "$HOME/absent.git"
"$ENVY_BIN" set OFFLINE < "$HOME/value" > /dev/null 2> "$HOME/offline.err"
status_ok
shows 'Sync (cached upstream): ahead 1, behind 1'

# Even stale status is read-only: forbid network commands and decryption.
real_git=$(command -v git)
export real_git
mkdir "$HOME/bin"
cat > "$HOME/bin/git" <<'GIT'
#!/bin/sh
for argument do
    case $argument in
        fetch|push|pull|clone|ls-remote)
            printf 'network\n' >> "$HOME/forbidden-calls"
            exit 1 ;;
    esac
done
exec "$real_git" "$@"
GIT
cat > "$HOME/bin/age" <<'AGE'
#!/bin/sh
printf 'decryption\n' >> "$HOME/forbidden-calls"
exit 1
AGE
chmod +x "$HOME/bin/git" "$HOME/bin/age"
PATH=$HOME/bin:$PATH
export PATH
printf 'not ciphertext\n' > "$store/secrets/TOKEN.age"
printf '1\n' > "$XDG_STATE_HOME/envy/last-fetch"
cp "$XDG_STATE_HOME/envy/last-fetch" "$HOME/saved-fetch"
store_head=$(git -C "$store" rev-parse HEAD)
remote_head=$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)
store_state=$(git -C "$store" status --porcelain)
mkdir -p "$XDG_STATE_HOME/envy/lock/$$"
status_ok
shows 'Sync (cached upstream): ahead 1, behind 1'
shows 'Last fetch: 1 (epoch seconds)'
shows 'Fetch cache: stale (sync interval: 14400 seconds)'
cmp "$HOME/saved-fetch" "$XDG_STATE_HOME/envy/last-fetch" || fail 'status changed fetch time'
rmdir "$XDG_STATE_HOME/envy/lock/$$" "$XDG_STATE_HOME/envy/lock"
rm "$XDG_STATE_HOME/envy/last-fetch"
status_ok
shows 'Last fetch: never'
printf 'private invalid timestamp\n' > "$XDG_STATE_HOME/envy/last-fetch"
status_ok
shows 'Last fetch: invalid timestamp'
grep -F 'private invalid timestamp' "$HOME/status.out" "$HOME/status.err" > /dev/null && fail 'status echoed invalid state'
printf '%s\n' "$(date +%s)" > "$XDG_STATE_HOME/envy/last-fetch"
status_ok
shows 'Fetch cache: fresh (sync interval: 14400 seconds)'
git -C "$store" config --unset branch.main.remote
status_ok
shows 'Sync (cached upstream): ahead unknown, behind unknown (no cached upstream)'
[ ! -e "$HOME/forbidden-calls" ] || fail 'status fetched or decrypted'
assert_equal "$(git -C "$store" rev-parse HEAD)" "$store_head" 'status changed local history'
assert_equal "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" "$remote_head" 'status changed remote history'
assert_equal "$(git -C "$store" status --porcelain)" "$store_state" 'status changed store files'
for value in 'throwaway status secret' 'second line' 'private literal text' 'private overwritten literal' \
    'private project literal' 'private malformed text' 'throwaway-status-passphrase'; do
    grep -F "$value" "$HOME/status-log" > /dev/null && fail 'status exposed a value'
done
if "$ENVY_BIN" status extra > "$HOME/extra.out" 2> "$HOME/extra.err"; then
    fail 'status accepted extra arguments'
fi
[ ! -s "$HOME/extra.out" ] || fail 'invalid status arguments printed output'
grep -Fx 'envy: usage: envy status' "$HOME/extra.err" > /dev/null || fail 'missing status usage'
for path in "$XDG_DATA_HOME/envy"/.status.*; do
    [ ! -e "$path" ] || fail 'status left temporary files'
done
