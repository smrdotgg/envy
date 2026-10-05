#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

# Require a real UTF-8 locale; prefer the one that exposed macOS collation.
utf8_locale=
for candidate in en_US.UTF-8 C.UTF-8 C.utf8; do
    if charmap=$(LC_ALL=$candidate locale charmap 2> /dev/null); then
        case $charmap in UTF-8|UTF8) utf8_locale=$candidate; break ;; esac
    fi
done
[ -n "$utf8_locale" ] || fail 'name validation test requires a UTF-8 locale'
printf 'name validation locales: C, %s\n' "$utf8_locale"

python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-name-locale-passphrase
throwaway-name-locale-passphrase
RESPONSES
store=$XDG_DATA_HOME/envy/store
printf 'throwaway locale value' > "$HOME/value"
cat > "$HOME/editor" <<'EDITOR'
#!/bin/sh
cp "$HOME/map-input" "$1"
EDITOR
chmod +x "$HOME/editor"
EDITOR=$HOME/editor
export EDITOR
mkdir "$HOME/bash-as-sh"
ln -s "$(command -v bash)" "$HOME/bash-as-sh/sh"

# Values stay in files and stdin, including when the child observes exports.
cat > "$HOME/observe.py" <<'PY'
import os
import sys
from pathlib import Path

expected = Path(os.environ['HOME'], 'value').read_text()
assert all(os.environ[alias] == expected for alias in sys.argv[1:])
PY
for name_locale in C "$utf8_locale"; do
    for name_shell in dash "$HOME/bash-as-sh/sh"; do
        LC_ALL=$name_locale
        export LC_ALL
        for name in TOKEN _TOKEN0 Z9; do
            "$name_shell" "$ENVY_BIN" set "$name" < "$HOME/value"
            "$name_shell" "$ENVY_BIN" get "$name" > actual
            cmp "$HOME/value" actual || fail 'valid secret name changed value'
        done
        revision=$(git -C "$store" rev-parse HEAD)
        for name in '' lowercase Mixed 1DIGIT WITH-DASH 'WITH SPACE' ../ESCAPE A/B A=B 'A
B' ÉTOKEN TOKéN; do
            for action in set get; do
                if "$name_shell" "$ENVY_BIN" "$action" "$name" < "$HOME/value" > invalid.out 2> invalid.err; then
                    fail "invalid secret name accepted ($name_shell, $name_locale, $name)"
                fi
                [ ! -s invalid.out ] || fail 'invalid secret name printed stdout'
                grep 'invalid secret name' invalid.err > /dev/null || fail 'invalid secret name not diagnosed'
            done
        done
        assert_equal "$(git -C "$store" rev-parse HEAD)" "$revision" 'invalid secret name changed history'

        : > "$HOME/map-input"
        for name in demo 2nd_project.v1 z-9; do
            "$name_shell" "$ENVY_BIN" project edit "$name"
            "$name_shell" "$ENVY_BIN" project show "$name" > shown
            [ ! -s shown ] || fail 'blank mapping changed'
        done
        revision=$(git -C "$store" rev-parse HEAD)
        for name in '' ../escape Upper UPPER 'two words' -option .hidden a/b a=b 'a
b' café Éclair; do
            for action in edit show; do
                if "$name_shell" "$ENVY_BIN" project "$action" "$name" > invalid.out 2> invalid.err; then
                    fail "invalid project name accepted ($name_shell, $name_locale, $name)"
                fi
                [ ! -s invalid.out ] || fail 'invalid project name printed stdout'
                grep 'invalid project name' invalid.err > /dev/null || fail 'invalid project name not diagnosed'
            done
        done
        assert_equal "$(git -C "$store" rev-parse HEAD)" "$revision" 'invalid project name changed history'

        for alias in TOKEN apiToken lower_case _private A0; do
            printf '%s=TOKEN\n' "$alias"
        done > "$HOME/map-input"
        "$name_shell" "$ENVY_BIN" project edit demo
        "$name_shell" "$ENVY_BIN" env --project demo > exports
        cat exports > evaluate.sh
        cat >> evaluate.sh <<'EVALUATE'
python3 "$HOME/observe.py" TOKEN apiToken lower_case _private A0
EVALUATE
        "$name_shell" evaluate.sh
        "$name_shell" "$ENVY_BIN" run --project demo -- \
            python3 "$HOME/observe.py" TOKEN apiToken lower_case _private A0
        revision=$(git -C "$store" rev-parse HEAD)
        for alias in '' 1DIGIT WITH-DASH 'WITH SPACE' A/B ENVY_PRIVATE _ENVY_PRIVATE café Ålias 'A
B'; do
            printf '%s=TOKEN\n' "$alias" > "$HOME/map-input"
            if "$name_shell" "$ENVY_BIN" project edit demo > invalid.out 2> invalid.err; then
                fail "invalid alias accepted ($name_shell, $name_locale, $alias)"
            fi
            [ ! -s invalid.out ] || fail 'invalid alias printed stdout'
            [ -s invalid.err ] || fail 'invalid alias not diagnosed'
            assert_equal "$(git -C "$store" rev-parse HEAD)" "$revision" 'invalid alias changed history'
        done
        assert_equal "$(git -C "$store" status --porcelain)" '' 'name validation dirtied store'
    done
done

# Exercise the emitted hook through directory transitions in both supported
# shells. Lowercase, mixed-case, underscore and digit aliases must all unload.
mkdir -p "$HOME/bin" "$HOME/project" "$HOME/outside"
ln -s "$ENVY_BIN" "$HOME/bin/envy"
PATH=$HOME/bin:$PATH
export PATH
(cd "$HOME/project" && "$ENVY_BIN" link --local demo)
cat > "$HOME/session" <<'SESSION'
set -eu
cd "$HOME/outside"
eval "$(envy hook)"
cd "$HOME/project"
_envy_hook 2> "$HOME/hook-notice"
python3 "$HOME/observe.py" TOKEN apiToken lower_case _private A0
cd "$HOME/outside"
_envy_hook 2> "$HOME/hook-notice"
python3 - <<'PY'
import os
assert all(alias not in os.environ for alias in ['TOKEN', 'apiToken', 'lower_case', '_private', 'A0'])
PY
[ "$LC_ALL" = "$NAME_TEST_LOCALE" ]
SESSION
for name_locale in C "$utf8_locale"; do
    for hook_shell in bash zsh; do
        LC_ALL=$name_locale NAME_TEST_LOCALE=$name_locale "$hook_shell" -f "$HOME/session"
    done
done
