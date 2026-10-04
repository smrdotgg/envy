#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

ENVY_INSTALL_SOURCE=$ENVY_BIN
export ENVY_INSTALL_SOURCE
python3 "$TEST_ROOT/tests/pty-helper.py" -- dash "$TEST_ROOT/install.sh" "$TEST_REMOTE" <<'RESPONSES'
throwaway-doctor-passphrase
throwaway-doctor-passphrase
RESPONSES
installed=$HOME/.local/bin/envy
store=$XDG_DATA_HOME/envy/store
identity=$XDG_DATA_HOME/envy/identity
PATH=$HOME/.local/bin:$PATH
export PATH
"$installed" config quiet on
printf 'throwaway doctor value\nsecond line\n' > value
"$installed" set TOKEN < value
git -C "$store" config status.showUntrackedFiles no

doctor_ok() {
    "$installed" doctor < /dev/null > doctor.out 2> doctor.err || fail 'healthy doctor failed'
    [ ! -s doctor.err ] || fail 'healthy doctor wrote diagnostics to stderr'
    grep '^FAIL ' doctor.out > /dev/null && fail 'healthy doctor reported a failure'
    cat doctor.out doctor.err >> doctor-log
}
doctor_bad() {
    if "$installed" doctor < /dev/null > doctor.out 2> doctor.err; then
        fail 'doctor succeeded on a broken setup'
    fi
    cat doctor.out doctor.err >> doctor-log
}
shows() {
    grep -F "$1" doctor.out > /dev/null || fail 'doctor omitted expected check'
}

before_head=$(git -C "$store" rev-parse HEAD)
before_fetch=$(cat "$XDG_STATE_HOME/envy/last-fetch")
before_key=$(git hash-object "$identity")
doctor_ok
for check in 'dependency git:' 'dependency age:' 'dependency age-keygen:' \
    'store format' 'identity matches store' 'store cleanliness' 'remote reachable' \
    'hook bash' 'hook zsh' 'PATH resolves this envy executable' \
    'permissions executable' 'permissions identity' 'permissions data' \
    'permissions store' 'permissions state' 'permissions config' 'permissions settings'; do
    shows "PASS $check"
done
assert_equal "$(git -C "$store" rev-parse HEAD)" "$before_head" 'doctor changed store history'
assert_equal "$(cat "$XDG_STATE_HOME/envy/last-fetch")" "$before_fetch" 'doctor fetched'
assert_equal "$(git hash-object "$identity")" "$before_key" 'doctor changed identity'
assert_equal "$(git -C "$store" status --porcelain --untracked-files=all)" '' 'doctor dirtied store'

# Reachability does not require a particular remote HEAD or any existing refs.
fixture_remote "$HOME/empty-remote.git"
git -C "$store" remote set-url origin "$HOME/empty-remote.git"
doctor_ok
shows 'PASS remote reachable'
git -C "$store" remote set-url origin "$TEST_REMOTE"

# A remote probe must not decrypt, fetch, push, change git configuration or prompt.
mkdir stubs
real_git=$(command -v git)
real_age=$(command -v age)
export real_git real_age
cat > stubs/git <<'GIT'
#!/bin/sh
printf '%s\n' "$*" >> "$HOME/git-calls"
case "$*" in
    *ls-remote*)
        [ "$GIT_TERMINAL_PROMPT" = 0 ] && [ "$GIT_ASKPASS" = false ] &&
            [ "$SSH_ASKPASS" = false ] && [ "$SSH_ASKPASS_REQUIRE" = force ] || exit 1
        case $GIT_SSH_COMMAND in *-oBatchMode=yes) ;; *) exit 1 ;; esac
        ;;
esac
exec "$real_git" "$@"
GIT
cat > stubs/age <<'AGE'
#!/bin/sh
[ "$1" = --version ] || exit 1
exec "$real_age" "$@"
AGE
chmod +x stubs/git stubs/age
PATH=$PWD/stubs:$PATH doctor_ok
for operation in fetch push clone rebase; do
    grep "$operation" "$HOME/git-calls" > /dev/null && fail 'doctor mutated remote state'
done

# Independent failures must all be reported, including hidden untracked files.
cp "$identity" saved-identity
age-keygen -o other-identity > /dev/null 2>&1
cp other-identity "$identity"
chmod 644 "$identity"
chmod 755 "$XDG_DATA_HOME/envy" "$store" "$XDG_STATE_HOME/envy" "$XDG_CONFIG_HOME/envy"
chmod 644 "$XDG_CONFIG_HOME/envy/config"
chmod 777 "$installed"
printf 'untracked fixture\n' > "$store/untracked"
git -C "$store" remote set-url origin "$HOME/nonexistent.git"
rm "$HOME/.bashrc"
printf '# >>> envy >>>\n' > "$HOME/.zshrc"
doctor_bad
for check in 'identity:' 'store cleanliness:' 'remote reachability:' 'hook bash:' 'hook zsh:' \
    'permissions executable:' 'permissions identity:' 'permissions data:' \
    'permissions store:' 'permissions state:' 'permissions config:' 'permissions settings:'; do
    shows "FAIL $check"
done
shows 'PASS PATH resolves this envy executable'
cp saved-identity "$identity"
chmod 600 "$identity" "$XDG_CONFIG_HOME/envy/config"
chmod 700 "$XDG_DATA_HOME/envy" "$store" "$XDG_STATE_HOME/envy" "$XDG_CONFIG_HOME/envy"
chmod 755 "$installed"
rm "$store/untracked"
git -C "$store" remote set-url origin "$TEST_REMOTE"
dash "$TEST_ROOT/install.sh" > reinstall.out 2> reinstall.err && fail 'installer accepted malformed markers'
rm "$HOME/.zshrc"
dash "$TEST_ROOT/install.sh" > reinstall.out
doctor_ok

# Missing dependencies and old versions do not hide the other diagnostics.
mkdir isolated
for utility in sh awk cat ls id sed git age-keygen bash zsh; do
    ln -s "$(command -v "$utility")" "isolated/$utility"
done
PATH=$PWD/isolated doctor_bad
shows 'FAIL dependency age: missing'
shows 'PASS identity matches store'
shows 'FAIL PATH:'
cat > isolated/age <<'OLD'
#!/bin/sh
printf '0.9.0\n'
OLD
chmod +x isolated/age
PATH=$PWD/isolated doctor_bad
shows 'FAIL dependency age: unsupported'
rm isolated/age
ln -s "$real_age" isolated/age
rm isolated/age-keygen
PATH=$PWD/isolated doctor_bad
shows 'FAIL dependency age-keygen: missing'
shows 'FAIL identity:'

# Missing/corrupt keys, newer formats and unfinished operations are failures.
mv "$identity" saved-current-identity
doctor_bad
shows 'FAIL identity:'
shows 'FAIL permissions identity:'
mv saved-current-identity "$identity"
printf '2\n' > "$store/format"
mkdir "$store/.git/rebase-merge"
doctor_bad
shows 'FAIL store format:'
shows 'FAIL store cleanliness:'
rmdir "$store/.git/rebase-merge"
git -C "$store" checkout -- format

# No store still gets a full diagnosis rather than stopping at the first check.
XDG_DATA_HOME=$HOME/empty-data "$installed" doctor > empty.out 2> empty.err && fail 'uninitialized doctor passed'
grep '^FAIL identity:' empty.out > /dev/null || fail 'uninitialized diagnosis stopped early'
grep '^PASS PATH ' empty.out > /dev/null || fail 'uninitialized diagnosis omitted machine checks'
if "$installed" doctor extra > args.out 2> args.err; then fail 'doctor accepted arguments'; fi
grep 'usage: envy doctor' args.err > /dev/null || fail 'doctor lacks usage diagnostic'

python3 - <<'PY'
from pathlib import Path
assert Path('value').read_bytes().splitlines()[0] not in Path('doctor-log').read_bytes()
assert b'AGE-SECRET-KEY-' not in Path('doctor-log').read_bytes()
PY
