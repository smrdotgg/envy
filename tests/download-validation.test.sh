#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

# Both download paths validate the same file without running it. All downloads
# use a local stub, including the URL case, and need no store or terminal.
mkdir -p "$HOME/.local/bin" stubs
cp "$ENVY_BIN" "$HOME/.local/bin/envy"
cp "$ENVY_BIN" installed-before
printf 'keep bash startup\n' > "$HOME/.bashrc"
printf 'keep zsh startup\n' > "$HOME/.zshrc"
cp "$HOME/.bashrc" bash-before
cp "$HOME/.zshrc" zsh-before
candidate=$PWD/candidate
export candidate
cat > stubs/curl <<'CURL'
#!/bin/sh
[ "$1" = -fsSL ] && [ "$2" = https://example.invalid/envy ] && [ "$3" = -o ] || exit 1
cp "$candidate" "$4"
CURL
chmod +x stubs/curl
PATH=$PWD/stubs:$PATH
export PATH

assert_preserved() {
    cmp installed-before "$HOME/.local/bin/envy" || fail 'validation replaced installed executable'
    cmp bash-before "$HOME/.bashrc" || fail 'validation changed bash startup'
    cmp zsh-before "$HOME/.zshrc" || fail 'validation changed zsh startup'
    [ ! -e "$HOME/candidate-executed" ] || fail 'validation executed downloaded code'
    set -- "$HOME/.local/bin"/.envy-install.* "$HOME/.local/bin"/.envy-update.*
    for staging do
        [ ! -e "$staging" ] || fail 'validation left a staging directory'
    done
}

for invalid in unrelated empty syntax html no-version duplicate-version wrong-shebang; do
    case $invalid in
        unrelated) printf '#!/bin/sh\nENVY_VERSION=9.0\ntouch "$HOME/candidate-executed"\n' > "$candidate" ;;
        empty) : > "$candidate" ;;
        syntax) printf '#!/bin/sh\nENVY_VERSION=9.0\nif broken syntax\n' > "$candidate" ;;
        html) printf '<html>wrong download</html>\n' > "$candidate" ;;
        no-version) sed '/^ENVY_VERSION=/d' "$ENVY_BIN" > "$candidate" ;;
        duplicate-version) sed '/^ENVY_VERSION=/a\
ENVY_VERSION=9.0
' "$ENVY_BIN" > "$candidate" ;;
        wrong-shebang) sed '1s|.*|#!/bin/bash|' "$ENVY_BIN" > "$candidate" ;;
    esac
    for source in "$candidate" https://example.invalid/envy; do
        if ENVY_INSTALL_SOURCE=$source dash "$TEST_ROOT/install.sh" < /dev/null > install.out 2> install.err; then
            fail 'installer accepted an invalid candidate'
        fi
        [ -s install.err ] || fail 'installer rejection lacks a diagnostic'
        assert_preserved
        if ENVY_UPDATE_SOURCE=$source "$HOME/.local/bin/envy" self-update < /dev/null > update.out 2> update.err; then
            fail 'updater accepted an invalid candidate'
        fi
        grep 'current version unchanged' update.err > /dev/null || fail 'update rejection lacks preservation diagnostic'
        assert_preserved
    done
done

# A genuine build remains acceptable even when top-level code would have a
# visible side effect if validation tried to execute, source, or probe it.
sed '2i\
touch "$HOME/candidate-executed"
' "$ENVY_BIN" > "$candidate"
ENVY_UPDATE_SOURCE=$candidate "$HOME/.local/bin/envy" self-update > accepted-update.out
cmp "$candidate" "$HOME/.local/bin/envy" || fail 'updater rejected genuine program structure'
[ ! -e "$HOME/candidate-executed" ] || fail 'updater executed genuine candidate during validation'
cp "$ENVY_BIN" "$HOME/.local/bin/envy"
ENVY_INSTALL_SOURCE=https://example.invalid/envy dash "$TEST_ROOT/install.sh" < /dev/null > accepted-install.out
cmp "$candidate" "$HOME/.local/bin/envy" || fail 'installer rejected genuine program structure'
[ ! -e "$HOME/candidate-executed" ] || fail 'installer executed genuine candidate during validation'
