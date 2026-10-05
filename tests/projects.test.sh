#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-project-passphrase
throwaway-project-passphrase
RESPONSES
store=$XDG_DATA_HOME/envy/store
printf '%s' 'throwaway project value' | "$ENVY_BIN" set TOKEN

# A controllable editor, including an option supplied through EDITOR.
cat > "$HOME/editor" <<'EDITOR_SCRIPT'
#!/bin/sh
set -eu
[ "$1" = --fixture-option ]
shift
printf '%s\n' opened >> "$HOME/editor-calls"
cp "$HOME/edit-input" "$1"
EDITOR_SCRIPT
chmod +x "$HOME/editor"
EDITOR="$HOME/editor --fixture-option"
export EDITOR

"$ENVY_BIN" project ls > projects.out
[ ! -s projects.out ] || fail 'empty store listed projects'
printf '# central mapping\napiToken=TOKEN\nTOKEN\n' > "$HOME/edit-input"
"$ENVY_BIN" project edit demo > edit.out 2> edit.err
[ ! -s edit.out ] && [ ! -s edit.err ] || fail 'valid edit produced output'
[ -f "$HOME/editor-calls" ] || fail 'project edit did not open EDITOR'
"$ENVY_BIN" project show demo > shown
cmp "$HOME/edit-input" shown || fail 'project show differs from edited map'
git --git-dir="$TEST_REMOTE" show HEAD:projects/demo/map > pushed
cmp shown pushed || fail 'project map was not pushed'
assert_equal "$(git -C "$store" log -1 --format=%s)" 'project edit demo' 'project edit commit subject'
assert_equal "$(git -C "$store" status --porcelain)" '' 'valid edit left a dirty store'
assert_equal "$(git -C "$store" diff-tree --no-commit-id --name-only -r HEAD)" projects/demo/map 'edit committed unrelated files'

# An unchanged edit succeeds without manufacturing a commit.
revision=$(git -C "$store" rev-parse HEAD)
"$ENVY_BIN" project edit demo
assert_equal "$(git -C "$store" rev-parse HEAD)" "$revision" 'unchanged edit created a commit'

for name in demo new-project; do
    printf 'good=TOKEN\nbad=MISSING\n' > "$HOME/edit-input"
    if "$ENVY_BIN" project edit "$name" > invalid.out 2> invalid.err; then
        fail 'invalid project edit succeeded'
    fi
    [ ! -s invalid.out ] || fail 'invalid project edit printed stdout'
    grep -F "projects/$name/map:2: bad: secret not found: MISSING" invalid.err > /dev/null || fail 'invalid edit lacks file, line and key'
    assert_equal "$(git -C "$store" rev-parse HEAD)" "$revision" 'invalid edit changed history'
    assert_equal "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" "$revision" 'invalid edit changed the remote'
    assert_equal "$(git -C "$store" status --porcelain)" '' 'invalid edit left uncommitted files'
done
[ ! -e "$store/projects/new-project" ] || fail 'invalid edit created a project'
"$ENVY_BIN" project show demo > after-invalid
cmp shown after-invalid || fail 'invalid edit replaced the existing map'

EDITOR=false
export EDITOR
if "$ENVY_BIN" project edit demo > failed.out 2> failed.err; then
    fail 'failed editor was accepted'
fi
grep 'editor failed' failed.err > /dev/null || fail 'editor failure not diagnosed'
assert_equal "$(git -C "$store" status --porcelain)" '' 'failed editor dirtied the store'
EDITOR="$HOME/editor --fixture-option"
export EDITOR

# Blank mappings are valid and still create a named project.
: > "$HOME/edit-input"
"$ENVY_BIN" project edit 2nd_project.v1
"$ENVY_BIN" project ls > projects.out
printf '2nd_project.v1\ndemo\n' > expected-projects
LC_ALL=C sort projects.out > sorted-projects
cmp expected-projects sorted-projects || fail 'project ls omitted or changed names'
"$ENVY_BIN" project show 2nd_project.v1 > empty-map
[ ! -s empty-map ] || fail 'blank project mapping changed'

# Writes inherit dirty-store protection and offline commit retention.
printf 'unrelated\n' > "$store/unrelated"
revision=$(git -C "$store" rev-parse HEAD)
for action in edit rm; do
    if "$ENVY_BIN" project "$action" demo > dirty.out 2> dirty.err; then
        fail 'project write accepted a dirty store'
    fi
    grep 'store has uncommitted changes' dirty.err > /dev/null || fail 'dirty project write not diagnosed'
    assert_equal "$(git -C "$store" rev-parse HEAD)" "$revision" 'dirty refusal changed history'
done
rm "$store/unrelated"
git -C "$store" remote set-url origin "$HOME/absent.git"
printf 'Renamed=TOKEN\n' > "$HOME/edit-input"
"$ENVY_BIN" project edit demo > offline.out 2> offline.err
grep 'warning:.*local commit retained' offline.err > /dev/null || fail 'offline project edit lost its commit'
"$ENVY_BIN" project show demo > offline-map
cmp "$HOME/edit-input" offline-map || fail 'offline project edit lost the mapping'
git -C "$store" remote set-url origin "$TEST_REMOTE"
"$ENVY_BIN" sync > /dev/null

"$ENVY_BIN" project rm demo > rm.out 2> rm.err
[ ! -s rm.out ] && [ ! -s rm.err ] || fail 'project removal produced output'
[ ! -e "$store/projects/demo" ] || fail 'project removal kept the directory'
assert_equal "$(git -C "$store" log -1 --format=%s)" 'project rm demo' 'project removal commit subject'
assert_equal "$(git -C "$store" rev-parse HEAD)" "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" 'project removal was not pushed'
"$ENVY_BIN" get TOKEN > secret-still-present
[ -s secret-still-present ] || fail 'project removal deleted a secret'
for action in show rm; do
    if "$ENVY_BIN" project "$action" demo > missing.out 2> missing.err; then
        fail 'missing project was accepted'
    fi
    grep 'project not found: demo' missing.err > /dev/null || fail 'missing project not diagnosed'
done

# Split only the fixed argument table below, with pathname expansion disabled.
set -f
for args in '' 'unknown' 'ls extra' 'show' 'show demo extra' 'edit' 'rm'; do
    # Intentional splitting of the fixed table above; globbing is disabled.
    # shellcheck disable=SC2086
    set -- $args
    if "$ENVY_BIN" project "$@" > args.out 2> args.err; then
        fail 'invalid project arguments were accepted'
    fi
    grep 'usage: envy project' args.err > /dev/null || fail 'project argument error lacks usage'
done
set +f
for name in '' ../escape Upper 'two words' '-option' '.hidden' 'a/b'; do
    if "$ENVY_BIN" project edit "$name" > name.out 2> name.err; then
        fail 'invalid project name was accepted'
    fi
    grep 'invalid project name' name.err > /dev/null || fail 'invalid project name not diagnosed'
done
assert_equal "$(git -C "$store" status --porcelain)" '' 'project commands left the store dirty'
set -- "$XDG_DATA_HOME/envy"/.project.*
[ ! -e "$1" ] || fail 'project edit left temporary files'
