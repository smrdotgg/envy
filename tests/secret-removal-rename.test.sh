#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-rename-passphrase
throwaway-rename-passphrase
RESPONSES
store=$XDG_DATA_HOME/envy/store

assert_clean() {
    assert_equal "$(git -C "$store" status --porcelain --untracked-files=all)" '' 'command left a dirty store'
    [ ! -d "$XDG_STATE_HOME/envy/lock" ] || fail 'command left the store locked'
    for temporary in "$XDG_DATA_HOME/envy"/.rm.* "$XDG_DATA_HOME/envy"/.mv.*; do
        [ ! -e "$temporary" ] || fail 'command left temporary files'
    done
}

assert_rejected() {
    before=$(git -C "$store" rev-parse HEAD)
    remote_before=$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)
    if "$ENVY_BIN" "$@" > rejected.out 2> rejected.err; then
        fail 'invalid or unsafe secret operation succeeded'
    fi
    [ ! -s rejected.out ] || fail 'rejected command wrote stdout'
    [ -s rejected.err ] || fail 'rejected command had no explanation'
    assert_equal "$(git -C "$store" rev-parse HEAD)" "$before" 'rejected command changed history'
    assert_equal "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" "$remote_before" 'rejected command changed the remote'
    assert_clean
}

assert_pushed_once() {
    assert_equal "$(git -C "$store" rev-list --count HEAD)" "$((count + 1))" 'operation did not create exactly one commit'
    assert_equal "$(git -C "$store" log -1 --format=%s)" "$1" 'operation commit message'
    assert_equal "$(git -C "$store" rev-parse HEAD)" "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" 'operation was not pushed'
    assert_clean
}

# No mappings directory or global file is required for removal or rename.
printf '%s' 'throwaway unused value' | "$ENVY_BIN" set UNUSED
count=$(git -C "$store" rev-list --count HEAD)
"$ENVY_BIN" rm UNUSED > rm.out 2> rm.err
[ ! -s rm.out ] || fail 'unreferenced removal produced stdout'
[ ! -s rm.err ] || fail 'unreferenced removal produced stderr'
[ ! -e "$store/secrets/UNUSED.age" ] || fail 'removal kept the secret'
assert_pushed_once 'rm UNUSED'
assert_rejected get UNUSED
grep 'secret not found: UNUSED' rejected.err > /dev/null || fail 'removed secret remained readable'

printf 'throwaway-rename-value-marker\nwith '\''quotes $ and ` text\n\n' > value
printf '%s\n' throwaway-rename-value-marker > secret-marker
"$ENVY_BIN" set OLD < value
cp "$store/secrets/OLD.age" ciphertext
count=$(git -C "$store" rev-list --count HEAD)
"$ENVY_BIN" mv OLD TEMP > mv.out 2> mv.err
assert_pushed_once 'mv OLD TEMP'
cmp ciphertext "$store/secrets/TEMP.age" || fail 'rename changed the ciphertext'
"$ENVY_BIN" mv TEMP OLD > /dev/null 2> mv.err
for name in OTHER OLD_SUFFIX LITERAL_ONLY PROJECT_ONLY GLOBAL_ONLY; do
    "$ENVY_BIN" set "$name" < value
done

cat > "$HOME/editor" <<'EDITOR'
#!/bin/sh
cp "$HOME/map-input" "$1"
EDITOR
chmod +x "$HOME/editor"
EDITOR=$HOME/editor
export EDITOR

cat > "$HOME/map-input" <<'GLOBAL'
# OLD stays in comments
OLD
GlobalAlias=OLD
GlobalAlias=__literal__("last assignment wins")
OLD_ALIAS=OTHER
Prefix=OLD_SUFFIX
Literal=__literal__("OLD")
GlobalOnly=GLOBAL_ONLY

GLOBAL
"$ENVY_BIN" project edit --global
cat > "$HOME/map-input" <<'ALPHA'
# project alpha
lowercase=OLD
OLD
Duplicates=OLD
Duplicates=OTHER
ProjectOnly=PROJECT_ONLY
ALPHA
"$ENVY_BIN" project edit alpha
printf 'OtherAlias=OLD\n' > "$HOME/map-input"
"$ENVY_BIN" project edit beta
printf '# OLD\nOLD=OTHER\nLiteral=__literal__("OLD LITERAL_ONLY")\nPrefix=OLD_SUFFIX' > "$HOME/map-input"
"$ENVY_BIN" project edit unchanged
cp "$store/projects/unchanged/map" unchanged-map

# Link metadata is independent of mapping references and must survive rename.
git -c init.defaultBranch=main init --quiet checkout
git -C checkout remote add origin "$HOME/project.git"
(cd checkout && "$ENVY_BIN" link alpha)
cp "$store/projects/alpha/remotes" remotes

# A reference in just the global mapping or just a central project blocks rm.
assert_rejected rm GLOBAL_ONLY
grep -F 'global:8: GlobalOnly' rejected.err > /dev/null || fail 'global-only reference was not listed'
assert_rejected rm PROJECT_ONLY
grep -F 'projects/alpha/map:6: ProjectOnly' rejected.err > /dev/null || fail 'project-only reference was not listed'
assert_rejected rm OLD
for location in 'global:2: OLD' 'global:3: GlobalAlias' 'projects/alpha/map:2: lowercase' \
    'projects/alpha/map:3: OLD' 'projects/alpha/map:4: Duplicates' 'projects/beta/map:1: OtherAlias'; do
    grep -F "$location" rejected.err > /dev/null || fail 'removal omitted a reference location'
done
grep -F -- '--force' rejected.err > /dev/null || fail 'refusal lacked force advice'
if grep -F 'projects/unchanged/map' rejected.err > /dev/null; then
    fail 'alias, comment or literal was treated as a secret reference'
fi

# Literal mentions alone do not prevent removal.
count=$(git -C "$store" rev-list --count HEAD)
"$ENVY_BIN" rm LITERAL_ONLY
assert_pushed_once 'rm LITERAL_ONLY'

# Bad names, destinations and arity must leave both repositories unchanged.
for name in '' lowercase Mixed 1DIGIT 'WITH-DASH' 'WITH SPACE' '../ESCAPE' 'A/B' 'A=B'; do
    assert_rejected mv OLD "$name"
    grep 'invalid secret name' rejected.err > /dev/null || fail 'invalid destination not diagnosed'
    assert_rejected mv "$name" NEW
    assert_rejected rm "$name"
done
assert_rejected mv OLD OTHER
grep 'secret already exists: OTHER' rejected.err > /dev/null || fail 'occupied destination not diagnosed'
assert_rejected mv OLD OLD
assert_rejected mv MISSING NEW
grep 'secret not found: MISSING' rejected.err > /dev/null || fail 'missing rename source not diagnosed'
assert_rejected rm MISSING
assert_rejected mv
assert_rejected mv OLD
assert_rejected mv OLD NEW extra
assert_rejected rm
assert_rejected rm OLD extra
assert_rejected rm --force OLD extra
grep 'usage: envy' rejected.err > /dev/null || fail 'argument error lacked usage'

# A malformed mapping must not leave even an earlier validated rewrite behind.
printf 'Bad =OLD\n' > "$store/projects/beta/map"
git -C "$store" add -- projects/beta/map
git -C "$store" commit --quiet -m 'fixture invalid mapping'
git -C "$store" push --quiet
assert_rejected mv OLD NEW
grep 'projects/beta/map:1: Bad:' rejected.err > /dev/null || fail 'invalid central mapping not diagnosed'
assert_rejected rm OLD
printf 'OtherAlias=OLD\n' > "$HOME/map-input"
"$ENVY_BIN" project edit beta

# Rename ignores approval and leaves the current in-project file untouched.
printf 'Local=OLD\n' > .envy
cp .envy saved-inproject
count=$(git -C "$store" rev-list --count HEAD)
"$ENVY_BIN" mv OLD NEW > mv.out 2> mv.err
[ ! -s mv.out ] || fail 'rename wrote stdout'
grep -F 'warning: in-project .envy files are not updated' mv.err > /dev/null || fail 'rename omitted the in-project warning'
assert_pushed_once 'mv OLD NEW'
cmp saved-inproject .envy || fail 'rename modified an in-project mapping'
cmp remotes "$store/projects/alpha/remotes" || fail 'rename changed project remote metadata'
cmp unchanged-map "$store/projects/unchanged/map" || fail 'rename changed an unrelated map'
cmp ciphertext "$store/secrets/NEW.age" || fail 'rename re-encrypted or changed ciphertext'
[ ! -e "$store/secrets/OLD.age" ] || fail 'rename kept the old secret'
"$ENVY_BIN" get NEW > actual
cmp value actual || fail 'rename changed multiline value bytes'
assert_rejected get OLD

cat > expected-global <<'GLOBAL'
# OLD stays in comments
OLD=NEW
GlobalAlias=NEW
GlobalAlias=__literal__("last assignment wins")
OLD_ALIAS=OTHER
Prefix=OLD_SUFFIX
Literal=__literal__("OLD")
GlobalOnly=GLOBAL_ONLY

GLOBAL
cat > expected-alpha <<'ALPHA'
# project alpha
lowercase=NEW
OLD=NEW
Duplicates=NEW
Duplicates=OTHER
ProjectOnly=PROJECT_ONLY
ALPHA
printf 'OtherAlias=NEW\n' > expected-beta
for pair in 'global expected-global' 'projects/alpha/map expected-alpha' 'projects/beta/map expected-beta'; do
    path=${pair%% *}
    expected=${pair#* }
    cmp "$expected" "$store/$path" || fail 'rename failed to rewrite central references exactly'
    git --git-dir="$TEST_REMOTE" show "HEAD:$path" > remote-map
    cmp "$expected" remote-map || fail 'rename did not push every central rewrite'
done
git -C "$store" diff-tree --no-commit-id --name-only --no-renames -r HEAD > changed-paths
printf 'global\nprojects/alpha/map\nprojects/beta/map\nsecrets/NEW.age\nsecrets/OLD.age\n' > expected-paths
cmp expected-paths changed-paths || fail 'rename committed unexpected paths'

rm .envy
"$ENVY_BIN" check > check.out 2> check.err
[ ! -s check.err ] || fail 'renamed central maps did not validate'
"$ENVY_BIN" config sync_interval 9999999999
cat > observe.sh <<'CHILD'
#!/bin/sh
printf '%s' "$OLD"
CHILD
"$ENVY_BIN" run --project alpha -- dash observe.sh > child-value
cmp value child-value || fail 'rename changed the exported alias or value'

# Force removes a referenced secret without silently rewriting its mappings.
cp "$store/global" before-force-global
assert_rejected rm NEW
count=$(git -C "$store" rev-list --count HEAD)
"$ENVY_BIN" rm NEW --force > force.out 2> force.err
[ ! -s force.out ] || fail 'force removal produced stdout'
[ ! -s force.err ] || fail 'force removal produced stderr'
assert_pushed_once 'rm NEW'
cmp before-force-global "$store/global" || fail 'force removal changed references'
if "$ENVY_BIN" check > check.out 2> check.err; then
    fail 'force removal did not leave missing references visible to check'
fi
grep 'secret not found: NEW' check.err > /dev/null || fail 'check omitted forced removal damage'
"$ENVY_BIN" set NEW < value
count=$(git -C "$store" rev-list --count HEAD)
"$ENVY_BIN" rm --force NEW
assert_pushed_once 'rm NEW'

# Clear the broken references for further independent operations.
"$ENVY_BIN" project rm alpha
"$ENVY_BIN" project rm beta
"$ENVY_BIN" project rm unchanged
: > "$HOME/map-input"
"$ENVY_BIN" project edit --global
printf 'Local=OTHER\n' > .envy
count=$(git -C "$store" rev-list --count HEAD)
"$ENVY_BIN" rm OTHER
assert_pushed_once 'rm OTHER'
rm .envy

# Refuse dirty stores and mismatched identities before deleting or moving files.
"$ENVY_BIN" set OFFLINE < value
revision=$(git -C "$store" rev-parse HEAD)
printf 'unrelated\n' > "$store/unrelated"
for action in rm mv; do
    case $action in
        rm) set -- rm --force OFFLINE ;;
        mv) set -- mv OFFLINE RENAMED ;;
    esac
    if "$ENVY_BIN" "$@" > dirty.out 2> dirty.err; then
        fail 'secret operation accepted a dirty store'
    fi
    grep 'store has uncommitted changes' dirty.err > /dev/null || fail 'dirty store not diagnosed'
    assert_equal "$(git -C "$store" rev-parse HEAD)" "$revision" 'dirty refusal changed history'
    [ -f "$store/secrets/OFFLINE.age" ] || fail 'dirty refusal removed the source'
    [ ! -e "$store/secrets/RENAMED.age" ] || fail 'dirty refusal created the destination'
done
rm "$store/unrelated"
cp "$store/recipient" saved-recipient
age-keygen -o alternate-identity 2> /dev/null
age-keygen -y alternate-identity > "$store/recipient"
for action in rm mv; do
    case $action in
        rm) set -- rm --force OFFLINE ;;
        mv) set -- mv OFFLINE RENAMED ;;
    esac
    if "$ENVY_BIN" "$@" > identity.out 2> identity.err; then
        fail 'secret operation accepted a mismatched identity'
    fi
    grep 'run envy unlock' identity.err > /dev/null || fail 'identity mismatch lacked recovery advice'
    [ -f "$store/secrets/OFFLINE.age" ] || fail 'identity refusal removed the source'
    [ ! -e "$store/secrets/RENAMED.age" ] || fail 'identity refusal created the destination'
done
mv saved-recipient "$store/recipient"
assert_clean

# Offline writes retain their commits, including all central rewrites.
printf 'OfflineAlias=OFFLINE\n' > "$HOME/map-input"
"$ENVY_BIN" project edit --global
git -C "$store" remote set-url origin "$HOME/absent.git"
remote_revision=$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)
count=$(git -C "$store" rev-list --count HEAD)
"$ENVY_BIN" mv OFFLINE RENAMED > offline.out 2> offline.err
grep 'warning:.*local commit retained' offline.err > /dev/null || fail 'offline rename lacked retained commit warning'
assert_equal "$(git -C "$store" rev-list --count HEAD)" "$((count + 1))" 'offline rename did not commit once'
assert_equal "$(git -C "$store" log -1 --format=%s)" 'mv OFFLINE RENAMED' 'offline rename commit message'
assert_equal "$(cat "$store/global")" 'OfflineAlias=RENAMED' 'offline rename lost the reference rewrite'
"$ENVY_BIN" get RENAMED > actual
cmp value actual || fail 'offline rename lost the value'
assert_clean
"$ENVY_BIN" rm --force RENAMED > offline.out 2> offline.err
grep 'warning:.*local commit retained' offline.err > /dev/null || fail 'offline removal lacked retained commit warning'
[ ! -e "$store/secrets/RENAMED.age" ] || fail 'offline removal kept the secret'
assert_equal "$(git -C "$store" rev-list --count HEAD)" "$((count + 2))" 'offline removal did not commit once'
assert_equal "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" "$remote_revision" 'offline commands changed the remote'
assert_clean
git -C "$store" remote set-url origin "$TEST_REMOTE"
"$ENVY_BIN" sync > /dev/null
assert_equal "$(git -C "$store" rev-parse HEAD)" "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" 'sync lost offline operations'

git -C "$store" log --format=%B > history
for output in history rm.out rm.err mv.out mv.err force.out force.err rejected.out rejected.err offline.out offline.err; do
    if grep -F -f secret-marker "$output" > /dev/null; then
        fail 'secret value appeared in an operation diagnostic or commit message'
    fi
done
assert_clean
