#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

ENVY_INSTALL_SOURCE=$ENVY_BIN
export ENVY_INSTALL_SOURCE
python3 "$TEST_ROOT/tests/pty-helper.py" -- dash "$TEST_ROOT/install.sh" "$TEST_REMOTE" <<'RESPONSES'
throwaway-uninstall-passphrase
throwaway-uninstall-passphrase
RESPONSES
test_home=$HOME
data=$XDG_DATA_HOME/envy
cp -R "$data" "$HOME/saved-data"
remote_before=$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)

case_home() {
    HOME=$test_home/$1
    XDG_DATA_HOME=$HOME/custom\ data
    XDG_STATE_HOME=$HOME/state
    XDG_CONFIG_HOME=$HOME/config
    export HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CONFIG_HOME
    mkdir -p "$HOME" "$XDG_DATA_HOME"
    cp -R "$test_home/saved-data" "$XDG_DATA_HOME/envy"
    printf 'export KEEP_BEFORE=yes\n' > "$HOME/.bashrc"
    printf 'export KEEP_ZSH=yes\n' > "$HOME/.zshrc"
    dash "$TEST_ROOT/install.sh" > installed.out
    printf 'export KEEP_AFTER=yes\n' >> "$HOME/.bashrc"
    installed=$HOME/.local/bin/envy
}
removed() {
    [ ! -e "$installed" ] || fail 'uninstall retained executable'
    for rc in .bashrc .zshrc; do
        grep 'envy' "$HOME/$rc" > /dev/null && fail 'uninstall retained hook block'
    done
    grep '^export KEEP_BEFORE=yes$' "$HOME/.bashrc" > /dev/null || fail 'uninstall damaged earlier startup content'
    grep '^export KEEP_AFTER=yes$' "$HOME/.bashrc" > /dev/null || fail 'uninstall damaged later startup content'
    grep '^export KEEP_ZSH=yes$' "$HOME/.zshrc" > /dev/null || fail 'uninstall damaged zsh startup content'
    assert_equal "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" "$remote_before" 'uninstall changed remote history'
    [ -f "$TEST_REMOTE/HEAD" ] || fail 'uninstall deleted remote'
    set -- "$HOME/.local/bin"/.envy-uninstall.*
    [ ! -e "$1" ] || fail 'uninstall left temporary startup files'
    [ ! -d "$XDG_STATE_HOME/envy/lock" ] || fail 'uninstall retained lock'
}

# With no controlling terminal, default to retaining data; stdin is not consent.
case_home no-terminal
"$installed" uninstall <<'PIPE' > no-terminal.out 2> no-terminal.err
yes
PIPE
removed
[ -f "$XDG_DATA_HOME/envy/identity" ] || fail 'noninteractive uninstall deleted identity'
[ -d "$XDG_DATA_HOME/envy/store/.git" ] || fail 'noninteractive uninstall deleted clone'
[ ! -s no-terminal.err ] || fail 'noninteractive uninstall printed terminal open errors'
grep 'retained' no-terminal.out > /dev/null || fail 'uninstall did not explain retained data'

# A decline removes only the tool and hooks, including when startup is symlinked.
case_home declined
mv "$HOME/.bashrc" "$HOME/actual-bashrc"
ln -s "$HOME/actual-bashrc" "$HOME/.bashrc"
python3 "$TEST_ROOT/tests/pty-helper.py" --transcript declined-terminal -- "$installed" uninstall <<'ANSWER'
n
ANSWER
removed
[ -L "$HOME/.bashrc" ] || fail 'uninstall broke startup symlink'
[ -f "$XDG_DATA_HOME/envy/identity" ] || fail 'decline deleted identity'
[ -d "$XDG_DATA_HOME/envy/store/.git" ] || fail 'decline deleted clone'

# Confirmation deletes exactly the local key/clone, without invoking Git.
case_home confirmed
"$installed" config quiet on
mkdir -p "$XDG_STATE_HOME/envy"
printf 'keep machine-local trust\n' > "$XDG_STATE_HOME/envy/allowed"
mkdir "$HOME/stubs"
cat > "$HOME/stubs/git" <<'GIT'
#!/bin/sh
printf 'called\n' >> "$HOME/git-calls"
exit 1
GIT
chmod +x "$HOME/stubs/git"
python3 "$TEST_ROOT/tests/pty-helper.py" --transcript confirmed-terminal -- \
    env PATH="$HOME/stubs:$PATH" "$installed" uninstall <<'ANSWER'
yes
ANSWER
removed
[ ! -e "$HOME/git-calls" ] || fail 'uninstall contacted store remote'
[ ! -e "$XDG_DATA_HOME/envy/identity" ] || fail 'confirmed uninstall retained identity'
[ ! -e "$XDG_DATA_HOME/envy/store" ] || fail 'confirmed uninstall retained store clone'
[ -f "$XDG_CONFIG_HOME/envy/config" ] || fail 'uninstall removed unrelated settings'
[ -f "$XDG_STATE_HOME/envy/allowed" ] || fail 'uninstall removed unrelated trust state'
python3 - declined-terminal confirmed-terminal <<'PY'
from pathlib import Path
import sys
for name in sys.argv[1:]:
    text = Path(name).read_bytes()
    assert text.count(b'Delete local identity and store clone? [y/N]: ') == 1
assert b'local identity and store clone deleted' in Path('confirmed-terminal').read_bytes()
PY

# Malformed markers are refused before any startup file or executable is changed.
case_home damaged
cp "$HOME/.bashrc" bash-before
cp "$installed" script-before
printf '# >>> envy >>>\n' > "$HOME/.zshrc"
if "$installed" uninstall < /dev/null > damaged.out 2> damaged.err; then
    fail 'damaged markers were accepted'
fi
cmp bash-before "$HOME/.bashrc" || fail 'partial uninstall damaged valid startup file'
cmp script-before "$installed" || fail 'partial uninstall removed executable'
grep 'damaged envy startup markers' damaged.err > /dev/null || fail 'damaged markers not diagnosed'
[ -f "$XDG_DATA_HOME/envy/identity" ] || fail 'failed uninstall deleted identity'

# Before initialization there is no deletion prompt and missing rc files are fine.
case_home no-store
rm -rf "$XDG_DATA_HOME/envy"
rm "$HOME/.zshrc"
"$installed" uninstall < /dev/null > no-store.out 2> no-store.err
[ ! -e "$installed" ] || fail 'no-store uninstall retained executable'
[ ! -s no-store.err ] || fail 'no-store uninstall requested input'
[ ! -e "$HOME/.zshrc" ] || fail 'uninstall recreated missing startup file'

case_home arguments
if "$installed" uninstall --yes > args.out 2> args.err; then fail 'uninstall accepted unsupported flag'; fi
[ -f "$installed" ] || fail 'invalid uninstall arguments removed executable'
grep 'usage: envy uninstall' args.err > /dev/null || fail 'uninstall lacks usage diagnostic'
