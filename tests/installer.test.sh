#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

homes=$HOME/installer\ homes
source_file=$HOME/local\ envy
cp "$ENVY_BIN" "$source_file"
ENVY_INSTALL_SOURCE=$source_file
export ENVY_INSTALL_SOURCE
use_home() {
    HOME=$homes/$1
    XDG_DATA_HOME=$HOME/custom\ data
    XDG_CONFIG_HOME=$HOME/.config
    XDG_STATE_HOME=$HOME/.local/state
    GIT_CONFIG_GLOBAL=$HOME/.gitconfig
    export HOME XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME GIT_CONFIG_GLOBAL
    mkdir -p "$HOME"
}

snapshot() {
    python3 - "$HOME" "$XDG_DATA_HOME" <<'PY'
import hashlib
import os
import pathlib
import sys

for root in sys.argv[1:]:
    for directory, _, names in os.walk(root):
        for name in sorted(names):
            path = pathlib.Path(directory, name)
            info = path.stat()
            print(path, info.st_mode, info.st_mtime_ns,
                  hashlib.sha256(path.read_bytes()).hexdigest())
PY
}

# No URL installs only the executable and shell startup blocks, with no prompt.
use_home first
printf 'export KEEP_STARTUP=yes' > "$HOME/.bashrc"
dash "$TEST_ROOT/install.sh" < /dev/null > no-url.out 2> no-url.err
[ -x "$HOME/.local/bin/envy" ] || fail 'installer did not install an executable'
cmp "$ENVY_BIN" "$HOME/.local/bin/envy" || fail 'installed script differs from local source'
[ ! -e "$XDG_DATA_HOME/envy" ] || fail 'no-URL installation initialized a store'
[ ! -s no-url.err ] || fail 'no-URL installation prompted or failed'
for rc in .bashrc .zshrc; do
    [ -f "$HOME/$rc" ] || fail 'startup file was not created for an available shell'
    assert_equal "$(grep -c '^# >>> envy >>>$' "$HOME/$rc")" 1 'missing or duplicate startup block'
    assert_equal "$(grep -c '^# <<< envy <<<$' "$HOME/$rc")" 1 'missing startup end marker'
done
grep '^export KEEP_STARTUP=yes$' "$HOME/.bashrc" > /dev/null || fail 'installer damaged an unterminated startup line'
snapshot > no-url.before
dash "$TEST_ROOT/install.sh" < /dev/null > no-url-again.out
snapshot > no-url.after
cmp no-url.before no-url.after || fail 'no-URL rerun changed files or timestamps'

# Create a new store through a downloaded/piped installer; age still owns its tty.
ln -s "$TEST_REMOTE" installer-store.git
python3 "$TEST_ROOT/tests/pty-helper.py" --transcript create-terminal -- \
    dash -c 'cat "$TEST_ROOT/install.sh" | dash -s -- --yes ./installer-store.git' <<'RESPONSES'
throwaway-installer-passphrase
throwaway-installer-passphrase
RESPONSES
store=$XDG_DATA_HOME/envy/store
identity=$XDG_DATA_HOME/envy/identity
[ -f "$identity" ] || fail 'installer did not initialize the store identity'
python3 - create-terminal <<'PY'
import pathlib
import re
import sys
output = pathlib.Path(sys.argv[1]).read_bytes()
assert len(re.findall(rb"Enter passphrase[^\r\n]*?: ", output)) == 1
assert len(re.findall(rb"Confirm passphrase[^\r\n]*?: ", output)) == 1
assert b"throwaway-installer-passphrase" not in output
PY

printf '%s' 'throwaway installer environment value' > expected-value
"$HOME/.local/bin/envy" set BOOTSTRAP < expected-value
cat > "$HOME/editor" <<'EDITOR'
#!/bin/sh
printf 'InstalledToken=BOOTSTRAP\n' > "$1"
EDITOR
chmod +x "$HOME/editor"
EDITOR="'$HOME/editor'" "$HOME/.local/bin/envy" project edit bootstrap
project_dir=$HOME/project
export project_dir
git -c init.defaultBranch=main init --quiet "$project_dir"
git -C "$project_dir" remote add origin "$homes/project.git"
(cd "$project_dir" && "$HOME/.local/bin/envy" link bootstrap)

# Startup files must provide PATH and the hook in a new interactive shell.
cat > session <<'SESSION'
set -eu
_envy_hook
cd "$project_dir"
_envy_hook
printf '%s' "$InstalledToken" > "$HOME/loaded-value"
cd "$HOME"
_envy_hook
[ "${InstalledToken+x}" != x ]
case :$PATH: in
    *":$HOME/.local/bin:"*":$HOME/.local/bin:"*) exit 1 ;;
    *":$HOME/.local/bin:"*) ;;
    *) exit 1 ;;
esac
SESSION
session=$PWD/session
export session
for shell in bash zsh; do
    "$shell" -ic '. "$session"' > shell.out 2> shell.err || fail 'new interactive shell did not load and unload environment'
    cmp expected-value "$HOME/loaded-value" || fail 'ambient value differs after install'
done
# An existing PATH entry must not be duplicated by startup or by re-sourcing.
PATH="$HOME/.local/bin:$PATH" bash -ic '. "$HOME/.bashrc"; . "$session"' > shell.out 2> shell.err || fail 'startup duplicated install directory on PATH'
PATH="$HOME/.local/bin:$PATH" zsh -ic '. "$HOME/.zshrc"; . "$session"' > shell.out 2> shell.err || fail 'zsh startup duplicated install directory on PATH'
rm "$HOME/loaded-value"

# A configured rerun is local, non-interactive and preserves the whole home.
snapshot > configured.before
dash "$TEST_ROOT/install.sh" ./installer-store.git < /dev/null > relative.out 2> relative.err
[ ! -s relative.err ] || fail 'relative store URL rerun requested input'
snapshot > relative.after
cmp configured.before relative.after || fail 'relative store URL rerun changed files or timestamps'
# The absolute path to the same repository is also a harmless rerun.
dash "$TEST_ROOT/install.sh" "$TEST_REMOTE" < /dev/null > configured.out 2> configured.err
[ ! -s configured.err ] || fail 'configured rerun requested input'
snapshot > configured.after
cmp configured.before configured.after || fail 'configured rerun changed files or timestamps'
assert_equal "$(git -C "$store" status --porcelain)" '' 'installer dirtied configured store'

# Joining on another machine uses exactly one prompt, even from a script pipe.
use_home second
python3 "$TEST_ROOT/tests/pty-helper.py" --transcript join-terminal -- \
    dash -c 'cat "$TEST_ROOT/install.sh" | dash -s -- "$TEST_REMOTE"' <<'RESPONSES'
throwaway-installer-passphrase
RESPONSES
python3 - join-terminal <<'PY'
import pathlib
import re
import sys
output = pathlib.Path(sys.argv[1]).read_bytes()
assert len(re.findall(rb"Enter passphrase[^\r\n]*?: ", output)) == 1
assert b"Confirm passphrase" not in output
assert b"throwaway-installer-passphrase" not in output
PY
for shell in bash zsh; do
    "$shell" -ic '. "$session"' > shell.out 2> shell.err || fail 'joined machine shell did not load environment'
    cmp expected-value "$HOME/loaded-value" || fail 'joined machine environment differs'
done
rm "$HOME/loaded-value"
snapshot > joined.before
dash "$TEST_ROOT/install.sh" --yes "$TEST_REMOTE" < /dev/null > joined.out
snapshot > joined.after
cmp joined.before joined.after || fail 'joined machine rerun changed state'

# An unrelated store or incomplete identity must never be silently overwritten.
if dash "$TEST_ROOT/install.sh" "$homes/other.git" < /dev/null > different.out 2> different.err; then
    fail 'installer accepted a different store URL'
fi
grep 'different store URL' different.err > /dev/null || fail 'different store not diagnosed'
mv "$XDG_DATA_HOME/envy/identity" saved-identity
if dash "$TEST_ROOT/install.sh" "$TEST_REMOTE" < /dev/null > missing.out 2> missing.err; then
    fail 'installer accepted a missing identity'
fi
grep 'envy unlock' missing.err > /dev/null || fail 'missing identity lacks recovery instructions'
[ ! -e "$XDG_DATA_HOME/envy/identity" ] || fail 'rerun recreated a key or prompted'
mv saved-identity "$XDG_DATA_HOME/envy/identity"

# Download source override uses curl without reaching the network.
mkdir "$HOME/stubs"
cat > "$HOME/stubs/curl" <<'CURL'
#!/bin/sh
[ "$1" = -fsSL ] && [ "$2" = https://example.invalid/envy ] && [ "$3" = -o ] || exit 1
printf 'download\n' >> "$HOME/download-calls"
cp "$local_source" "$4"
CURL
chmod +x "$HOME/stubs/curl"
local_source=$source_file
export local_source
ENVY_INSTALL_SOURCE=https://example.invalid/envy PATH="$HOME/stubs:$PATH" \
    dash "$TEST_ROOT/install.sh" > download.out
assert_equal "$(cat "$HOME/download-calls")" download 'source URL not used by curl'
cmp "$local_source" "$HOME/.local/bin/envy" || fail 'downloaded script differs'
cp "$HOME/.local/bin/envy" installed-before
printf 'if broken syntax\n' > bad-source
if ENVY_INSTALL_SOURCE=$PWD/bad-source dash "$TEST_ROOT/install.sh" > bad.out 2> bad.err; then
    fail 'invalid download syntax was installed'
fi
cmp installed-before "$HOME/.local/bin/envy" || fail 'failed download replaced installed tool'
set -- "$HOME/.local/bin"/.envy-install.*
[ ! -e "$1" ] || fail 'installer left a temporary download'

# A malformed startup block is diagnosed before a duplicate can be appended.
printf '# >>> envy >>>\n' > "$HOME/.bashrc"
if dash "$TEST_ROOT/install.sh" > block.out 2> block.err; then
    fail 'damaged hook block was accepted'
fi
assert_equal "$(grep -c '^# >>> envy >>>$' "$HOME/.bashrc")" 1 'damaged block was duplicated'
grep 'damaged envy startup block' block.err > /dev/null || fail 'damaged block not diagnosed'
