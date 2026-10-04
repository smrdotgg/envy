#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

install_dir=$HOME/update\ bin
mkdir "$install_dir"
cp "$ENVY_BIN" "$install_dir/envy"
installed=$install_dir/envy
sed 's/^ENVY_VERSION=0.1.0-dev$/ENVY_VERSION=0.2.0/' "$ENVY_BIN" > release
release=$PWD/release
mkdir stubs
cat > stubs/curl <<'CURL'
#!/bin/sh
[ "$1" = -fsSL ] && [ "$3" = -o ] || exit 1
printf '%s\n' "$2" >> "$HOME/download-calls"
# A download must be staged on the executable's filesystem, never on TMPDIR.
case $4 in "$install_dir"/.envy-update.*/envy) ;; *) exit 1 ;; esac
if [ "${DOWNLOAD_FAIL-no}" = yes ]; then
    printf 'partial download\n' > "$4"
    exit 1
fi
cp "$release" "$4"
CURL
chmod +x stubs/curl
export install_dir release
PATH=$PWD/stubs:$PATH
export PATH

# Default URL follows the latest release rather than the development branch.
"$installed" self-update > update.out
assert_equal "$(cat update.out)" 'envy: updated 0.1.0-dev -> 0.2.0' 'update did not report both versions'
assert_equal "$(cat "$HOME/download-calls")" \
    'https://github.com/smrdotgg/envy/releases/latest/download/envy' 'update did not request latest tagged release'
assert_equal "$("$installed" version)" 'envy 0.2.0' 'new executable not active'
cmp "$release" "$installed" || fail 'installed release differs from downloaded bytes'
[ -x "$installed" ] || fail 'update lost executable permission'

assert_no_temp() {
    set -- "$install_dir"/.envy-update.*
    [ ! -e "$1" ] || fail 'update left temporary files'
}
assert_no_temp
cp "$installed" before
if DOWNLOAD_FAIL=yes "$installed" self-update > failed.out 2> failed.err; then
    fail 'failed partial download succeeded'
fi
cmp before "$installed" || fail 'failed download damaged current version'
assert_no_temp
grep 'current version unchanged' failed.err > /dev/null || fail 'failure lacks preservation diagnostic'

# Empty, invalid syntax and non-envy shell downloads leave the tool intact.
for corrupt in empty syntax html plain; do
    case $corrupt in
        empty) : > corrupt-source ;;
        syntax) printf '#!/bin/sh\nENVY_VERSION=0.3.0\nif broken syntax\n' > corrupt-source ;;
        html) printf '<html>not a release</html>\n' > corrupt-source ;;
        plain) printf '#!/bin/sh\nprintf "not envy\\n"\n' > corrupt-source ;;
    esac
    if ENVY_UPDATE_SOURCE=$PWD/corrupt-source "$installed" self-update > corrupt.out 2> corrupt.err; then
        fail 'corrupt update succeeded'
    fi
    cmp before "$installed" || fail 'corrupt update replaced current version'
    assert_no_temp
done

# Local and URL overrides support offline tests and explicit release sources.
sed 's/^ENVY_VERSION=0.2.0$/ENVY_VERSION=0.3.0/' "$release" > next-release
ENVY_UPDATE_SOURCE=$PWD/next-release "$installed" self-update > local.out
assert_equal "$("$installed" version)" 'envy 0.3.0' 'local update source ignored'
assert_equal "$(cat local.out)" 'envy: updated 0.2.0 -> 0.3.0' 'local update versions wrong'
ENVY_UPDATE_SOURCE=https://example.invalid/release-envy "$installed" self-update > custom.out
assert_equal "$(tail -1 "$HOME/download-calls")" 'https://example.invalid/release-envy' 'custom update URL ignored'
assert_no_temp

# PATH and relative invocations replace the invoked script, not another install.
ENVY_UPDATE_SOURCE=$PWD/next-release PATH="$install_dir:$PATH" envy self-update > path.out
assert_equal "$("$installed" version)" 'envy 0.3.0' 'PATH update replaced wrong file'
cp "$ENVY_BIN" ./relative-envy
ENVY_UPDATE_SOURCE=$PWD/next-release ./relative-envy self-update > relative.out
assert_equal "$(./relative-envy version)" 'envy 0.3.0' 'relative update replaced wrong file'
ln -s "$installed" linked-envy
cp "$installed" before
if ./linked-envy self-update > link.out 2> link.err; then fail 'symlink update accepted'; fi
cmp before "$installed" || fail 'symlink refusal changed executable'
[ -L linked-envy ] || fail 'symlink refusal removed link'
if "$installed" self-update extra > args.out 2> args.err; then fail 'update accepted arguments'; fi
grep 'usage: envy self-update' args.err > /dev/null || fail 'update lacks usage diagnostic'

# Update works before initialization and does not invent local keys or clones.
[ ! -e "$XDG_DATA_HOME/envy" ] || fail 'self-update initialized local store state'
