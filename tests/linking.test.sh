#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-link-passphrase
throwaway-link-passphrase
RESPONSES
store=$XDG_DATA_HOME/envy/store
printf '%s' 'throwaway linked value' | "$ENVY_BIN" set TOKEN
cat > "$HOME/editor" <<'EDITOR'
#!/bin/sh
cp "$HOME/map-input" "$1"
EDITOR
chmod +x "$HOME/editor"
EDITOR=$HOME/editor
export EDITOR
printf 'slice8_global=__literal__("global")\nslice8_shared=__literal__("global")\n' > "$HOME/map-input"
"$ENVY_BIN" project edit --global
cat > "$HOME/observe.sh" <<'OBSERVE'
printf '%s\n' "$slice8_global" "${slice8_project-absent}" "$slice8_shared"
OBSERVE
printf 'global\nabsent\nglobal\n' > "$HOME/expected-global"
printf 'global\nthrowaway linked value\nproject\n' > "$HOME/expected-app"
printf 'global\nlocal\nlocal\n' > "$HOME/expected-local"
unset slice8_global slice8_project slice8_shared

# Both CLI entry points must resolve and merge the same environment.
observe() (
    "$ENVY_BIN" env > "$HOME/exports" 2> "$HOME/read.err"
    [ ! -s "$HOME/read.err" ] || fail 'env emitted a diagnostic for a valid link'
    dash -c '. "$HOME/exports"; . "$HOME/observe.sh"' > "$HOME/observed"
    cmp "$1" "$HOME/observed" || fail 'env selected the wrong project'
    "$ENVY_BIN" run -- dash "$HOME/observe.sh" > "$HOME/observed" 2> "$HOME/read.err"
    [ ! -s "$HOME/read.err" ] || fail 'run emitted a diagnostic for a valid link'
    cmp "$1" "$HOME/observed" || fail 'run selected the wrong project'
)

# Build a real checkout and a second clone using local git repositories only.
app=$HOME/app
code_remote=$HOME/code.git
fixture_remote "$code_remote"
git -c init.defaultBranch=main init --quiet "$app"
printf 'checkout\n' > "$app/tracked"
git -C "$app" add tracked
git -C "$app" -c user.name=fixture -c user.email=fixture@localhost commit --quiet -m fixture
git -C "$app" remote add origin "$code_remote"
git -C "$app" push --quiet origin main
git clone --quiet "$code_remote" "$HOME/second-clone"
git -C "$app" remote set-url origin 'git@GitHub.COM:Owner/Repo.GIT/'
mkdir -p "$app/deep/subdirectory"
cd "$app/deep/subdirectory"
observe "$HOME/expected-global"
"$ENVY_BIN" link > "$HOME/link.out" 2> "$HOME/link.err"
[ ! -s "$HOME/link.out" ] && [ ! -s "$HOME/link.err" ] || fail 'remote link produced unexpected output'
"$ENVY_BIN" project show app > "$HOME/new-map"
[ ! -s "$HOME/new-map" ] || fail 'link did not create an empty project mapping'
git --git-dir="$TEST_REMOTE" show HEAD:projects/app/remotes > "$HOME/remotes"
printf 'github.com/owner/repo\n' > "$HOME/expected-remotes"
cmp "$HOME/expected-remotes" "$HOME/remotes" || fail 'remote was not normalized and pushed'
assert_equal "$(git -C "$store" log -1 --format=%s)" 'link app' 'link commit did not name the project'
assert_equal "$(git -C "$store" status --porcelain)" '' 'link left a dirty store'

printf 'slice8_project=TOKEN\nslice8_shared=__literal__("project")\n' > "$HOME/map-input"
"$ENVY_BIN" project edit app
observe "$HOME/expected-app"
revision=$(git -C "$store" rev-parse HEAD)

# URL spellings all match and linking the same remote twice is idempotent.
while IFS= read -r remote; do
    git -C "$app" remote set-url origin "$remote"
    observe "$HOME/expected-app"
    "$ENVY_BIN" link app
    assert_equal "$(git -C "$store" rev-parse HEAD)" "$revision" 'equivalent remote created another commit'
done <<'REMOTES'
https://github.com/owner/repo
HTTPS://GitHub.COM/Owner/Repo.git/
ssh://git@GITHUB.com:2222/OWNER/REPO.GIT
ssh://other-user@github.com:22/owner/repo/
https://another-user@github.com:443/Owner/Repo.git
http://github.com:8080/owner/repo.git
other-user@github.com:owner/repo
github.com:Owner/Repo.git
git://github.com:9418/owner/repo.git
github.com/owner/repo
REMOTES

# The second clone needs no link, even at a different path and URL spelling.
git -C "$HOME/second-clone" remote set-url origin 'https://github.com/OWNER/REPO.git/'
cd "$HOME/second-clone"
observe "$HOME/expected-app"
git -C "$app" worktree add --quiet -b fixture-worktree "$HOME/worktree"
mkdir -p "$HOME/worktree/nested"
cd "$HOME/worktree/nested"
observe "$HOME/expected-app"

# Duplicate ownership is refused before creating a project or a commit.
if "$ENVY_BIN" link other > "$HOME/duplicate.out" 2> "$HOME/duplicate.err"; then
    fail 'link assigned a remote to a second project'
fi
grep -F 'remote already linked to project: app' "$HOME/duplicate.err" > /dev/null || fail 'duplicate ownership was not diagnosed'
[ ! -e "$store/projects/other" ] || fail 'duplicate refusal created a project'
assert_equal "$(git -C "$store" rev-parse HEAD)" "$revision" 'duplicate refusal changed store history'

# One project may match several repositories; unlink removes only this origin.
git -C "$HOME/second-clone" remote set-url origin 'ssh://git@github.com:22/owner/other.git'
cd "$HOME/second-clone"
"$ENVY_BIN" link app
observe "$HOME/expected-app"
"$ENVY_BIN" unlink
observe "$HOME/expected-global"
git --git-dir="$TEST_REMOTE" show HEAD:projects/app/remotes > "$HOME/remotes"
cmp "$HOME/expected-remotes" "$HOME/remotes" || fail 'unlink removed other repository links'
assert_equal "$(git -C "$store" log -1 --format=%s)" 'unlink app' 'unlink commit did not name the project'
cd "$app"
observe "$HOME/expected-app"

# Local overrides do not alter the synced project or its remote list.
printf 'slice8_project=__literal__("local")\nslice8_shared=__literal__("local")\n' > "$HOME/map-input"
"$ENVY_BIN" project edit local-project
revision=$(git -C "$store" rev-parse HEAD)
"$ENVY_BIN" link --local local-project
observe "$HOME/expected-local"
cd "$app/deep/subdirectory"
observe "$HOME/expected-local"
assert_equal "$(git -C "$store" rev-parse HEAD)" "$revision" 'existing-project local link changed store history'
assert_equal "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" "$revision" 'local link changed the remote store'
cd "$HOME/worktree/nested"
observe "$HOME/expected-app"

# A different machine state sees the remote project, never the local override.
(
    XDG_STATE_HOME=$HOME/second-state
    export XDG_STATE_HOME
    cd "$app"
    observe "$HOME/expected-app"
)
cd "$app/deep/subdirectory"
"$ENVY_BIN" unlink
observe "$HOME/expected-app"
assert_equal "$(git -C "$store" rev-parse HEAD)" "$revision" 'local unlink made a store commit'

# No-origin git checkouts and non-git scratch directories link locally.
no_origin=$HOME/no-origin
git -c init.defaultBranch=main init --quiet "$no_origin"
cd "$no_origin"
"$ENVY_BIN" link local-project
observe "$HOME/expected-local"
git remote add other 'git@github.com:owner/repo.git'
observe "$HOME/expected-local"
git remote add origin 'https://github.com/owner/repo.git'
observe "$HOME/expected-local"
"$ENVY_BIN" unlink
observe "$HOME/expected-app"

scratch=$HOME/scratch-project
mkdir -p "$scratch/deep"
cd "$scratch"
"$ENVY_BIN" link
"$ENVY_BIN" project show scratch-project > "$HOME/new-map"
[ ! -s "$HOME/new-map" ] || fail 'local link did not create a project'
git --git-dir="$TEST_REMOTE" show HEAD:projects/scratch-project/map > "$HOME/pushed-map"
[ ! -s "$HOME/pushed-map" ] || fail 'local project was not pushed'
[ ! -e "$store/projects/scratch-project/remotes" ] || fail 'local directory link was synced as a remote'
printf 'slice8_project=__literal__("local")\nslice8_shared=__literal__("local")\n' > "$HOME/map-input"
"$ENVY_BIN" project edit scratch-project
cd "$scratch/deep"
observe "$HOME/expected-local"
"$ENVY_BIN" unlink
observe "$HOME/expected-global"

# Local lookup uses exact physical paths, including whitespace and backslashes.
odd_path=$HOME/'scratch [x] \ directory'
mkdir -p "$odd_path/subdirectory" "$HOME/sibling"
cd "$odd_path"
"$ENVY_BIN" link --local local-project
ln -s "$odd_path" "$HOME/symlink"
cd "$HOME/symlink/subdirectory"
observe "$HOME/expected-local"
cd "$HOME/sibling"
observe "$HOME/expected-global"
cd "$odd_path/subdirectory"
"$ENVY_BIN" unlink
observe "$HOME/expected-global"

# Remote unlink propagates to every clone and worktree, preserving the map.
cd "$app/deep/subdirectory"
"$ENVY_BIN" unlink
[ -f "$store/projects/app/map" ] || fail 'remote unlink removed the project mapping'
[ ! -e "$store/projects/app/remotes" ] || fail 'remote unlink left its last remote'
observe "$HOME/expected-global"
cd "$HOME/worktree/nested"
observe "$HOME/expected-global"
git -C "$HOME/second-clone" remote set-url origin 'git@github.com:owner/repo.git'
cd "$HOME/second-clone"
observe "$HOME/expected-global"
"$ENVY_BIN" run --project app -- dash "$HOME/observe.sh" > "$HOME/observed"
cmp "$HOME/expected-app" "$HOME/observed" || fail 'explicit project override stopped working'

# Dirty writes refuse both link kinds and unlink without changing state.
"$ENVY_BIN" link app
printf 'unrelated\n' > "$store/unrelated"
revision=$(git -C "$store" rev-parse HEAD)
for action in remote local unlink; do
    case $action in
        remote) set -- link app ;;
        local) set -- link --local local-project ;;
        unlink) set -- unlink ;;
    esac
    if "$ENVY_BIN" "$@" > "$HOME/dirty.out" 2> "$HOME/dirty.err"; then
        fail 'link write accepted a dirty store'
    fi
    grep 'store has uncommitted changes' "$HOME/dirty.err" > /dev/null || fail 'dirty link write was not diagnosed'
    assert_equal "$(git -C "$store" rev-parse HEAD)" "$revision" 'dirty refusal changed history'
done
rm "$store/unrelated"
observe "$HOME/expected-app"

# Reads never contact a remote. Writes keep committed links when offline.
git -C "$store" remote set-url origin "$HOME/unavailable.git"
git -C "$HOME/second-clone" remote set-url origin 'https://example.test/owner/offline.git'
"$ENVY_BIN" link offline > "$HOME/offline.out" 2> "$HOME/offline.err"
grep 'warning:.*local commit retained' "$HOME/offline.err" > /dev/null || fail 'offline link lost its commit'
"$ENVY_BIN" project show offline > "$HOME/new-map"
"$ENVY_BIN" env > "$HOME/exports" 2> "$HOME/read.err"
[ ! -s "$HOME/read.err" ] || fail 'offline linked read touched the network'
"$ENVY_BIN" unlink > "$HOME/offline.out" 2> "$HOME/offline.err"
grep 'warning:.*local commit retained' "$HOME/offline.err" > /dev/null || fail 'offline unlink lost its commit'
git -C "$store" remote set-url origin "$TEST_REMOTE"
"$ENVY_BIN" sync > /dev/null

# Corrupt duplicate metadata is diagnosed by check and automatic resolution.
git -C "$HOME/second-clone" remote set-url origin 'git@github.com:owner/repo.git'
printf 'github.com/owner/repo\nexample.test/owner/shared\n' > "$store/projects/local-project/remotes"
printf 'example.test/owner/shared\n' > "$store/projects/offline/remotes"
if "$ENVY_BIN" check > "$HOME/check.out" 2> "$HOME/check.err"; then
    fail 'check accepted cross-project duplicate remotes'
fi
assert_equal "$(wc -l < "$HOME/check.err" | tr -d ' ')" 2 'check did not report every duplicate'
grep -F "$store/projects/local-project/remotes:1: duplicate remote" "$HOME/check.err" > /dev/null || fail 'check omitted duplicate file and line'
grep -F "$store/projects/app/remotes:1" "$HOME/check.err" > /dev/null || fail 'check omitted original remote location'
grep -F "$store/projects/offline/remotes:1: duplicate remote" "$HOME/check.err" > /dev/null || fail 'check omitted another duplicate remote'
for command in env run; do
    case $command in
        env) set -- env ;;
        run) set -- run -- dash -c 'touch "$HOME/child-ran"' ;;
    esac
    if "$ENVY_BIN" "$@" > "$HOME/failed.out" 2> "$HOME/failed.err"; then
        fail 'ambiguous automatic project resolution succeeded'
    fi
    [ ! -s "$HOME/failed.out" ] && [ ! -e "$HOME/child-ran" ] || fail 'ambiguous resolution loaded an environment'
done
rm "$store/projects/local-project/remotes" "$store/projects/offline/remotes"

for args in 'link app extra' 'link --unknown' 'link --local --local' 'link Upper' 'link ../escape' 'unlink extra'; do
    if printf '%s\n' "$args" | xargs "$ENVY_BIN" > "$HOME/args.out" 2> "$HOME/args.err"; then
        fail 'invalid link arguments succeeded'
    fi
    [ ! -s "$HOME/args.out" ] && [ -s "$HOME/args.err" ] || fail 'invalid link arguments lacked a diagnostic'
done
assert_equal "$(git -C "$store" status --porcelain)" '' 'link commands left store changes behind'
assert_equal "$(git -C "$store" rev-parse HEAD)" "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" 'link changes did not reach the remote'
git -C "$store" ls-tree -r --name-only HEAD > "$HOME/tracked-files"
grep -E '(^|/)(links|last-fetch|lock)$' "$HOME/tracked-files" > /dev/null && fail 'machine-local link state was synced'
for path in "$XDG_DATA_HOME/envy"/.link.* "$XDG_STATE_HOME/envy"/.links.*; do
    [ ! -e "$path" ] || fail 'link command left temporary files'
done
