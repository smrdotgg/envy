#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-approval-passphrase
throwaway-approval-passphrase
RESPONSES
store=$XDG_DATA_HOME/envy/store
printf '%s' 'throwaway global credential' | "$ENVY_BIN" set GLOBAL_KEY
printf '%s' 'throwaway central credential' | "$ENVY_BIN" set CENTRAL_KEY
printf '%s' 'throwaway repository credential' | "$ENVY_BIN" set REPO_KEY
cat > "$HOME/editor" <<'EDITOR'
#!/bin/sh
cp "$HOME/map-input" "$1"
EDITOR
chmod +x "$HOME/editor"
EDITOR=$HOME/editor
export EDITOR
printf 'Shared=GLOBAL_KEY\nGlobalOnly=GLOBAL_KEY\n' > "$HOME/map-input"
"$ENVY_BIN" project edit --global
printf 'Shared=CENTRAL_KEY\nCentralOnly=CENTRAL_KEY\n' > "$HOME/map-input"
"$ENVY_BIN" project edit app

app=$HOME/app
code_remote=$HOME/code.git
fixture_remote "$code_remote"
git -c init.defaultBranch=main init --quiet "$app"
printf 'checkout\n' > "$app/tracked"
git -C "$app" add tracked
git -C "$app" -c user.name=fixture -c user.email=fixture@localhost commit --quiet -m fixture
git -C "$app" remote add origin "$code_remote"
git -C "$app" push --quiet origin main
cd "$app"
"$ENVY_BIN" link app
cat > .envy <<'MAP'
Shared=REPO_KEY
Bare=REPO_KEY
REPO_KEY
Mode=__literal__("repo mode")
Overwritten=GLOBAL_KEY
Overwritten=__literal__("no credential")
MAP
mkdir -p "$app/deep/subdirectory"
cd "$app/deep/subdirectory"
revision=$(git -C "$store" rev-parse HEAD)

# An unapproved or changed project file stops all exports and child execution,
# including when a central project is explicitly selected.
refused() (
    rm -f "$HOME/child-ran"
    for command in env run explicit-env explicit-run; do
        case $command in
            env) set -- env ;;
            run) set -- run -- dash -c 'touch "$HOME/child-ran"' ;;
            explicit-env) set -- env --project app ;;
            explicit-run) set -- run --project app -- dash -c 'touch "$HOME/child-ran"' ;;
        esac
        if "$ENVY_BIN" "$@" > "$HOME/refused.out" 2> "$HOME/refused.err"; then
            fail 'unapproved project mapping loaded'
        fi
        [ ! -s "$HOME/refused.out" ] && [ ! -e "$HOME/child-ran" ] || fail 'trust failure emitted exports or ran a child'
        grep -F 'run envy allow' "$HOME/refused.err" > /dev/null || fail 'trust failure omitted allow guidance'
        grep -F '/.envy:' "$HOME/refused.err" > /dev/null || fail 'trust failure omitted mapping path'
    done
)
refused

# check validates before approval and includes current-file secret references.
"$ENVY_BIN" check > "$HOME/check.out" 2> "$HOME/check.err"
[ ! -s "$HOME/check.out" ] && [ ! -s "$HOME/check.err" ] || fail 'check ignored valid unapproved project references'
"$ENVY_BIN" allow > "$HOME/allow.out" 2> "$HOME/allow.err"
[ ! -s "$HOME/allow.err" ] || fail 'allow emitted an error'
for request in Shared=REPO_KEY Bare=REPO_KEY REPO_KEY=REPO_KEY Mode=__literal__ Overwritten=GLOBAL_KEY Overwritten=__literal__; do
    grep -Fx "$request" "$HOME/allow.out" > /dev/null || fail 'approval review omitted an alias or secret request'
done
for value in 'throwaway global credential' 'throwaway central credential' 'throwaway repository credential'; do
    grep -F "$value" "$HOME/allow.out" "$HOME/allow.err" > /dev/null && fail 'allow exposed a secret value'
done
hash=$(git hash-object --stdin < "$app/.envy")
grep -Fx "$hash $app/.envy" "$XDG_STATE_HOME/envy/allowed" > /dev/null || fail 'approval did not use Git object hash and absolute path'
cp "$XDG_STATE_HOME/envy/allowed" "$HOME/first-approval"
"$ENVY_BIN" allow > /dev/null
cmp "$HOME/first-approval" "$XDG_STATE_HOME/envy/allowed" || fail 'repeated approval duplicated state'

cat > "$HOME/observe.sh" <<'CHILD'
set -eu
printf '%s' "$GlobalOnly" > "$HOME/global-value"
printf '%s' "$CentralOnly" > "$HOME/central-value"
printf '%s' "$Shared" > "$HOME/shared-value"
printf '%s' "$Bare" > "$HOME/bare-value"
printf '%s' "$REPO_KEY" > "$HOME/repo-value"
[ "$Mode" = 'repo mode' ]
[ "$Overwritten" = 'no credential' ]
CHILD
observe() (
    "$ENVY_BIN" env > "$HOME/exports" 2> "$HOME/read.err"
    [ ! -s "$HOME/read.err" ] || fail 'approved env produced an error'
    assert_equal "$(grep -c '^export Shared=' "$HOME/exports")" 1 'three layers emitted duplicate aliases'
    dash -c '. "$HOME/exports"; . "$HOME/observe.sh"'
    "$ENVY_BIN" run -- dash "$HOME/observe.sh"
    "$ENVY_BIN" get GLOBAL_KEY > "$HOME/expected-global"
    "$ENVY_BIN" get CENTRAL_KEY > "$HOME/expected-central"
    "$ENVY_BIN" get REPO_KEY > "$HOME/expected-repo"
    cmp "$HOME/expected-global" "$HOME/global-value" || fail 'project file omitted global alias'
    cmp "$HOME/expected-central" "$HOME/central-value" || fail 'project file omitted central alias'
    for output in shared-value bare-value repo-value; do
        cmp "$HOME/expected-repo" "$HOME/$output" || fail 'project override or bare name did not load'
    done
)
observe

# Any byte change, including a comment, revokes approval until allow is run.
printf '# changed after approval\n' >> "$app/.envy"
refused
"$ENVY_BIN" allow > /dev/null
observe
assert_equal "$(wc -l < "$XDG_STATE_HOME/envy/allowed" | tr -d ' ')" 1 'reapproval retained stale approval for the path'

# Approval is per physical path: clones and worktrees need their own approval.
git clone --quiet "$code_remote" "$HOME/clone"
cp "$app/.envy" "$HOME/clone/.envy"
cd "$HOME/clone"
refused
"$ENVY_BIN" allow > /dev/null
observe
git -C "$app" worktree add --quiet -b approval-worktree "$HOME/worktree"
cp "$app/.envy" "$HOME/worktree/.envy"
cd "$HOME/worktree"
refused
"$ENVY_BIN" allow > /dev/null
observe

# A nested .envy in a git checkout does not introduce a subdirectory project.
cd "$app/deep/subdirectory"
printf 'Wrong=MISSING\n' > .envy
observe
rm .envy
# Symlinked directories address the same physical project root.
ln -s "$app" "$HOME/symlink"
cd "$HOME/symlink/deep/subdirectory"
observe

# Syntax and missing references are validated without approval; failed allow
# preserves prior approvals and never displays arbitrary malformed text.
cp "$app/.envy" "$HOME/saved-map"
cp "$XDG_STATE_HOME/envy/allowed" "$HOME/saved-approvals"
printf 'Good=REPO_KEY\nBad=__literal__("private"text")\nMissing=MISSING\n' > "$app/.envy"
for command in check allow; do
    if "$ENVY_BIN" "$command" > "$HOME/invalid.out" 2> "$HOME/invalid.err"; then
        fail 'invalid current project mapping passed validation'
    fi
    grep -F "$app/.envy:2: Bad:" "$HOME/invalid.err" > /dev/null || fail 'syntax error omitted path, line or alias'
    grep -F "$app/.envy:3: Missing: secret not found: MISSING" "$HOME/invalid.err" > /dev/null || fail 'missing secret error omitted location'
    grep -F 'private' "$HOME/invalid.err" > /dev/null && fail 'malformed mapping text leaked into errors'
    cmp "$HOME/saved-approvals" "$XDG_STATE_HOME/envy/allowed" || fail 'failed validation changed approvals'
done
refused
cp "$HOME/saved-map" "$app/.envy"
observe

# An approved file is still fully validated against the current store.
mv "$store/secrets/REPO_KEY.age" "$HOME/saved-secret.age"
for command in env run; do
    case $command in
        env) set -- env ;;
        run) set -- run -- dash -c 'touch "$HOME/child-ran"' ;;
    esac
    if "$ENVY_BIN" "$@" > "$HOME/invalid.out" 2> "$HOME/invalid.err"; then
        fail 'approved mapping loaded a missing secret'
    fi
    [ ! -s "$HOME/invalid.out" ] && [ ! -e "$HOME/child-ran" ] || fail 'invalid approved mapping partially loaded'
    grep -F "$app/.envy:1: Shared: secret not found: REPO_KEY" "$HOME/invalid.err" > /dev/null || fail 'approved mapping error omitted location'
done
mv "$HOME/saved-secret.age" "$store/secrets/REPO_KEY.age"

# A non-git directory needs no central link. The nearest ancestor .envy wins,
# even when an outer ancestor has a different approved mapping.
scratch=$HOME/'scratch [x] \ directory'
mkdir -p "$scratch/deep" "$scratch/inner/deep"
printf 'Scratch=REPO_KEY\nShared=__literal__("scratch")\n' > "$scratch/.envy"
cd "$scratch/deep"
refused
"$ENVY_BIN" allow > /dev/null
"$ENVY_BIN" run -- dash -c '[ "$Shared" = scratch ] && [ "${CentralOnly+x}" != x ]; printf "%s" "$Scratch"' > "$HOME/scratch-value"
cmp "$HOME/expected-repo" "$HOME/scratch-value" || fail 'non-git project did not load'
printf 'Shared=__literal__("inner")\n' > "$scratch/inner/.envy"
cd "$scratch/inner/deep"
refused
"$ENVY_BIN" allow > /dev/null
"$ENVY_BIN" run -- dash -c '[ "$Shared" = inner ] && [ "${Scratch+x}" != x ] && [ -n "$GlobalOnly" ]'
cd "$scratch/deep"
"$ENVY_BIN" run -- dash -c '[ "$Shared" = scratch ]'

# Git clean filters must not execute or hide raw mapping changes from approval.
cd "$app"
printf '.envy filter=approval-test\n' > .gitattributes
cat > "$HOME/filter" <<'FILTER'
#!/bin/sh
touch "$HOME/filter-ran"
cat > /dev/null
printf 'constant\n'
FILTER
chmod +x "$HOME/filter"
git config filter.approval-test.clean "$HOME/filter"
"$ENVY_BIN" allow > /dev/null
[ ! -e "$HOME/filter-ran" ] || fail 'allow executed a repository clean filter'
printf '# raw-byte change\n' >> .envy
refused
[ ! -e "$HOME/filter-ran" ] || fail 'trust verification executed a repository clean filter'
"$ENVY_BIN" allow > /dev/null

# Reads and approval are local even with an unavailable store remote.
git -C "$store" remote set-url origin "$HOME/unavailable.git"
"$ENVY_BIN" allow > /dev/null
observe
"$ENVY_BIN" check > "$HOME/check.out" 2> "$HOME/check.err"
[ ! -s "$HOME/check.err" ] || fail 'offline check contacted a remote'
git -C "$store" remote set-url origin "$TEST_REMOTE"
assert_equal "$(git -C "$store" rev-parse HEAD)" "$revision" 'approval or reads changed store history'
assert_equal "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" "$revision" 'approval changed remote history'
assert_equal "$(git -C "$store" status --porcelain)" '' 'approval dirtied the store'

# A second temporary home joins the same store but inherits no trust approvals.
(
    HOME=$HOME/second-home
    XDG_DATA_HOME=$HOME/data
    XDG_CONFIG_HOME=$HOME/config
    XDG_STATE_HOME=$HOME/state
    export HOME XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME
    mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"
    python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-approval-passphrase
RESPONSES
    cd "$app"
    refused
    "$ENVY_BIN" allow > /dev/null
    "$ENVY_BIN" run -- dash -c '[ "$Mode" = "repo mode" ] && [ -n "$Shared" ]'
)

# Broken state and non-file mappings fail closed; failures leave no temp files.
cd "$app"
mv "$XDG_STATE_HOME/envy/allowed" "$HOME/saved-approvals"
mkdir "$XDG_STATE_HOME/envy/allowed"
refused
if "$ENVY_BIN" allow > "$HOME/invalid.out" 2> "$HOME/invalid.err"; then
    fail 'allow accepted an approval directory'
fi
rmdir "$XDG_STATE_HOME/envy/allowed"
mv "$HOME/saved-approvals" "$XDG_STATE_HOME/envy/allowed"
mv .envy "$HOME/saved-map"
mkdir .envy
for command in env allow check; do
    if "$ENVY_BIN" "$command" > "$HOME/invalid.out" 2> "$HOME/invalid.err"; then
        fail 'non-file mapping was ignored'
    fi
    grep -F 'mapping is not a regular file' "$HOME/invalid.err" > /dev/null || fail 'non-file mapping lacked diagnostic'
done
rmdir .envy
mv "$HOME/saved-map" .envy
cd "$HOME/work"
if "$ENVY_BIN" allow > "$HOME/invalid.out" 2> "$HOME/invalid.err"; then
    fail 'allow succeeded without a project mapping'
fi
if "$ENVY_BIN" allow extra > "$HOME/invalid.out" 2> "$HOME/invalid.err"; then
    fail 'allow accepted extra arguments'
fi
for path in "$XDG_DATA_HOME/envy"/.allow.* "$XDG_DATA_HOME/envy"/.env.* "$XDG_DATA_HOME/envy"/.check.* "$XDG_STATE_HOME/envy"/.allowed.* "$XDG_STATE_HOME/envy/lock"; do
    [ ! -e "$path" ] || fail 'approval commands left temporary state'
done
