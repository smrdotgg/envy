#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

test_home=$HOME
test_path=$PATH
test_dash=$(command -v dash)
real_age=$(command -v age)
real_keygen=$(command -v age-keygen)
stub_path=$HOME/stubs
export real_age real_keygen stub_path
mkdir "$stub_path"
# An isolated PATH makes absent dependencies and shells portable to either CI OS.
for utility in awk cat chmod cmp cp git ln mkdir mktemp mv rm sh dash; do
    ln -s "$(command -v "$utility")" "$stub_path/$utility"
done
ln -s "$(command -v bash)" "$stub_path/bash"
cat > "$stub_path/id" <<'ID'
#!/bin/sh
[ "$1" = -u ] || exit 1
printf '%s\n' "$TEST_UID"
ID
cat > "$test_home/package-manager" <<'MANAGER'
#!/bin/sh
printf '%s' "${0##*/}" >> "$HOME/package-calls"
for argument do printf ' %s' "$argument" >> "$HOME/package-calls"; done
printf '\n' >> "$HOME/package-calls"
[ "${TEST_PACKAGE_FAIL-no}" = no ] || exit 1
if [ "$1" = install ] && [ "${TEST_PACKAGE_EMPTY-no}" = no ]; then
    ln -s "$real_age" "$stub_path/age"
    ln -s "$real_keygen" "$stub_path/age-keygen"
fi
MANAGER
cat > "$test_home/sudo" <<'SUDO'
#!/bin/sh
printf 'sudo\n' >> "$HOME/sudo-calls"
exec "$@"
SUDO
chmod +x "$stub_path/id" "$test_home/package-manager" "$test_home/sudo"
ENVY_INSTALL_SOURCE=$ENVY_BIN
TEST_UID=501
export ENVY_INSTALL_SOURCE TEST_UID

case_home() {
    HOME=$test_home/$1
    XDG_DATA_HOME=$HOME/data
    XDG_STATE_HOME=$HOME/state
    XDG_CONFIG_HOME=$HOME/config
    export HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CONFIG_HOME
    mkdir -p "$HOME"
    rm -f "$stub_path/age" "$stub_path/age-keygen" "$stub_path/brew" \
        "$stub_path/apt-get" "$stub_path/sudo"
}

# A decline stops before writing files; input from the pipe is not an answer.
case_home declined
cp "$test_home/package-manager" "$stub_path/brew"
python3 "$TEST_ROOT/tests/pty-helper.py" --transcript declined-terminal -- \
    env PATH="$stub_path" "$test_dash" -c 'printf "y\n" | dash "$TEST_ROOT/install.sh"' <<'RESPONSE' && fail 'declined installation succeeded'
n
RESPONSE
grep 'install age and age-keygen manually' declined-terminal > /dev/null || fail 'decline lacks instructions'
[ ! -e "$HOME/package-calls" ] || fail 'declining installed a package'
[ ! -e "$HOME/.local/bin/envy" ] || fail 'declining still installed the tool'

# Exactly one terminal confirmation; brew is preferred when both managers exist.
case_home brew
cp "$test_home/package-manager" "$stub_path/brew"
cp "$test_home/package-manager" "$stub_path/apt-get"
python3 "$TEST_ROOT/tests/pty-helper.py" --transcript brew-terminal -- \
    env PATH="$stub_path" "$test_dash" -c 'cat "$TEST_ROOT/install.sh" | dash -s --' <<'RESPONSE'
y
RESPONSE
assert_equal "$(cat "$HOME/package-calls")" 'brew install age' 'brew was not used exactly once'
python3 - brew-terminal declined-terminal <<'PY'
import pathlib
import sys
for path in sys.argv[1:]:
    output = pathlib.Path(path).read_bytes()
    assert output.count(b"Install age with brew? [y/N]: ") == 1
PY
[ -f "$HOME/.bashrc" ] || fail 'existing bash was not configured'
[ ! -e "$HOME/.zshrc" ] || fail 'unavailable zsh was configured'
PATH="$stub_path" "$test_dash" "$TEST_ROOT/install.sh" < /dev/null > brew-again.out
assert_equal "$(cat "$HOME/package-calls")" 'brew install age' 'rerun reinstalled age'

# --yes needs no terminal at all. apt-get uses sudo for a non-root user.
case_home apt-sudo
cp "$test_home/package-manager" "$stub_path/apt-get"
cp "$test_home/sudo" "$stub_path/sudo"
PATH="$stub_path" "$test_dash" "$TEST_ROOT/install.sh" --yes < /dev/null > apt.out 2> apt.err
[ ! -s apt.err ] || fail '--yes requested a confirmation'
printf 'apt-get update\napt-get install -y age\n' > expected-apt
cmp expected-apt "$HOME/package-calls" || fail 'apt-get commands differ'
assert_equal "$(wc -l < "$HOME/sudo-calls" | tr -d ' ')" 2 'apt-get did not use sudo'

# A root process uses apt-get directly, even when sudo exists.
case_home apt-root
cp "$test_home/package-manager" "$stub_path/apt-get"
cp "$test_home/sudo" "$stub_path/sudo"
TEST_UID=0 PATH="$stub_path" "$test_dash" "$TEST_ROOT/install.sh" --yes > root.out
cmp expected-apt "$HOME/package-calls" || fail 'root apt-get commands differ'
[ ! -e "$HOME/sudo-calls" ] || fail 'root install invoked sudo'

# Missing either binary requests the package; presence of age alone is insufficient.
case_home missing-keygen
cat > "$stub_path/age" <<'AGE'
#!/bin/sh
exec "$real_age" "$@"
AGE
chmod +x "$stub_path/age"
cat > "$stub_path/brew" <<'BREW'
#!/bin/sh
[ "$1" = install ] && [ "$2" = age ] || exit 1
printf 'brew install age\n' > "$HOME/package-calls"
ln -s "$real_keygen" "$stub_path/age-keygen"
BREW
chmod +x "$stub_path/brew"
PATH="$stub_path" "$test_dash" "$TEST_ROOT/install.sh" --yes > keygen.out
[ -f "$HOME/package-calls" ] || fail 'missing age-keygen was ignored'

# No terminal, no manager, insufficient privilege, and package failures all stop.
case_home no-terminal
cp "$test_home/package-manager" "$stub_path/brew"
if PATH="$stub_path" "$test_dash" "$TEST_ROOT/install.sh" < /dev/null > tty.out 2> tty.err; then
    fail 'missing terminal was accepted without --yes'
fi
grep 'no terminal available' tty.err > /dev/null || fail 'no-terminal error unclear'
[ ! -e "$HOME/package-calls" ] || fail 'no-terminal install invoked manager'

case_home no-manager
if PATH="$stub_path" "$test_dash" "$TEST_ROOT/install.sh" --yes > manager.out 2> manager.err; then
    fail 'no package manager was accepted'
fi
grep 'install age and age-keygen manually' manager.err > /dev/null || fail 'missing manager lacks instructions'

case_home no-sudo
cp "$test_home/package-manager" "$stub_path/apt-get"
if PATH="$stub_path" "$test_dash" "$TEST_ROOT/install.sh" --yes > sudo.out 2> sudo.err; then
    fail 'unprivileged apt-get without sudo was accepted'
fi
grep 'requires root or sudo' sudo.err > /dev/null || fail 'missing sudo not diagnosed'
[ ! -e "$HOME/package-calls" ] || fail 'unprivileged package installation attempted'

case_home package-failed
cp "$test_home/package-manager" "$stub_path/brew"
if TEST_PACKAGE_FAIL=yes PATH="$stub_path" "$test_dash" "$TEST_ROOT/install.sh" --yes > failed.out 2> failed.err; then
    fail 'failed package installation succeeded'
fi
[ ! -e "$HOME/.local/bin/envy" ] || fail 'package failure still installed envy'
grep 'could not install age' failed.err > /dev/null || fail 'package failure not diagnosed'

case_home package-empty
cp "$test_home/package-manager" "$stub_path/brew"
if TEST_PACKAGE_EMPTY=yes PATH="$stub_path" "$test_dash" "$TEST_ROOT/install.sh" --yes > empty.out 2> empty.err; then
    fail 'package without binaries accepted'
fi
grep 'did not provide age and age-keygen' empty.err > /dev/null || fail 'missing installed binaries not diagnosed'

# Available dependencies need no manager, and absent shells get no startup files.
case_home no-shells
ln -s "$real_age" "$stub_path/age"
ln -s "$real_keygen" "$stub_path/age-keygen"
rm "$stub_path/bash"
PATH="$stub_path" "$test_dash" "$TEST_ROOT/install.sh" > shells.out
[ -x "$HOME/.local/bin/envy" ] || fail 'tool not installed without supported shells'
[ ! -e "$HOME/.bashrc" ] && [ ! -e "$HOME/.zshrc" ] || fail 'installer configured missing shells'

# Extra and unknown arguments fail before any installation or prompting.
case_home bad-arguments
for arguments in '--unknown' 'one two'; do
    set -f
    # Fixture arguments are deliberately split to exercise CLI validation.
    set -- $arguments
    set +f
    if PATH="$test_path" "$test_dash" "$TEST_ROOT/install.sh" "$@" > args.out 2> args.err; then
        fail 'invalid installer arguments accepted'
    fi
    grep 'usage:' args.err > /dev/null || fail 'invalid arguments lack usage'
done
[ ! -e "$HOME/.local/bin/envy" ] || fail 'invalid arguments changed machine'
