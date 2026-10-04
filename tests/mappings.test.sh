#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-mapping-passphrase
throwaway-mapping-passphrase
RESPONSES
store=$XDG_DATA_HOME/envy/store

cat > "$HOME/editor" <<'EDITOR_SCRIPT'
#!/bin/sh
cp "$HOME/map-input" "$1"
EDITOR_SCRIPT
chmod +x "$HOME/editor"
EDITOR=$HOME/editor
export EDITOR

# Exercise the parser with an empty secret-name set, including a missing name.
: > "$HOME/map-input"
"$ENVY_BIN" project edit blank
"$ENVY_BIN" env --project blank > blank.out
[ ! -s blank.out ] || fail 'empty store and mapping emitted exports'
printf 'Alias=SECRET\n' > "$store/projects/blank/map"
if "$ENVY_BIN" env --project blank > missing.out 2> missing.err; then
    fail 'empty secret set accepted a reference'
fi
[ ! -s missing.out ] || fail 'missing name in empty store emitted exports'
grep -F "$store/projects/blank/map:1: Alias: secret not found: SECRET" missing.err > /dev/null || fail 'empty secret set lacks missing-reference error'
git -C "$store" checkout -- projects/blank/map

# Values reach the CLI through stdin only. Environment values lose trailing
# newlines, but retain quotes, embedded newlines, whitespace and shell syntax.
cat > value <<'VALUE'
throwaway 'quoted' "value" \\ $HOME $(touch should-not-exist) `touch should-not-exist`
second line	with spaces
VALUE
printf '\n\n' >> value
printf '%s' "$(cat value)" > expected
printf '%s' 'throwaway replacement' > replacement
: > empty
printf '\n\n' > newlines
printf '  spaces\tand carriage return\r '\''\\' > quotes
for pair in 'SECRET value' '_SECOND replacement' 'EMPTY empty' 'NEWLINES newlines' 'QUOTES quotes'; do
    name=${pair%% *}
    input=${pair#* }
    "$ENVY_BIN" set "$name" < "$input"
done

# Table-driven valid grammar, through both env and run. Every case binds SECRET
# or its replacement to the listed alias; the child observes only that alias.
while IFS='|' read -r alias mapping expected_file; do
    printf '%s\n' "$mapping" > "$HOME/map-input"
    "$ENVY_BIN" project edit demo
    "$ENVY_BIN" env --project demo > exports 2> env.err
    [ ! -s env.err ] || fail 'valid mapping produced stderr'
    # Use a script file so emitted values never become a process argument.
    cat exports > evaluate.sh
    printf 'printf "%%s" "$%s"\n' "$alias" >> evaluate.sh
    dash evaluate.sh > evaluated
    cmp "$expected_file" evaluated || fail 'env exports changed the value'
    printf 'printf "%%s" "$%s"\n' "$alias" > observe.sh
    "$ENVY_BIN" run --project demo -- dash observe.sh > child-value
    cmp "$expected_file" child-value || fail 'run did not export the mapped value'
    [ ! -e should-not-exist ] || fail 'emitted value executed shell syntax'
done <<'VALID'
SECRET|SECRET|expected
Alias|Alias=SECRET|expected
lower_case|lower_case=SECRET|expected
_private|_private=_SECOND|replacement
EMPTY|EMPTY|empty
NEWLINES|NEWLINES|empty
Quotes|Quotes=QUOTES|quotes
VALID

printf '# comment containing = and spaces\n\nAlias=SECRET\nAlias=_SECOND\nAlias=SECRET\n_SECOND' > "$HOME/map-input"
"$ENVY_BIN" project edit demo
"$ENVY_BIN" env --project demo > exports
assert_equal "$(grep -c '^export Alias=' exports)" 1 'last-wins merge emitted a duplicate alias'
cat exports > evaluate.sh
printf '\nprintf "%%s" "$Alias" > merged\nprintf "%%s" "$_SECOND" > bare\n' >> evaluate.sh
dash evaluate.sh
cmp expected merged || fail 'last assignment did not win'
cmp replacement bare || fail 'unterminated bare-name line did not resolve'
"$ENVY_BIN" run --project demo -- dash -c 'exit 37' > status.out 2> status.err && status=0 || status=$?
assert_equal "$status" 37 'run did not return the child status'
[ ! -s status.out ] && [ ! -s status.err ] || fail 'run printed unsolicited output'
"$ENVY_BIN" run --project demo -- dash -c 'test "$1" = "two words" && test "$2" = "*"' child 'two words' '*'
inherited_umask=$(umask)
umask 022
"$ENVY_BIN" run --project demo -- dash -c umask > child-umask
assert_equal "$(cat child-umask)" "$(umask)" 'run changed the child file-creation mask'
umask "$inherited_umask"

# Several aliases are loaded together, overriding only the child's environment.
Alias='inherited throwaway value'
export Alias
cat > observe-all.sh <<'CHILD'
#!/bin/sh
printf '%s' "$Alias" > all-alias
printf '%s' "$_SECOND" > all-bare
printf '%s' "$UNRELATED" > all-inherited
CHILD
UNRELATED='inherited throwaway value'
export UNRELATED
"$ENVY_BIN" run --project demo -- dash observe-all.sh
cmp expected all-alias || fail 'run did not replace an inherited mapped alias'
cmp replacement all-bare || fail 'run omitted a second export'
assert_equal "$(cat all-inherited)" "$UNRELATED" 'run changed an unrelated inherited variable'
assert_equal "$Alias" "$UNRELATED" 'run changed the parent environment'

# Empty mappings emit nothing and still allow a command to run.
: > "$HOME/map-input"
"$ENVY_BIN" project edit blank
"$ENVY_BIN" env --project blank > blank.out
[ ! -s blank.out ] || fail 'empty mapping emitted exports'
"$ENVY_BIN" run --project blank -- dash -c 'printf ran' > blank-run
assert_equal "$(cat blank-run)" ran 'empty mapping did not run the child'

# Fixtures deliberately introduce invalid central maps to test the read path.
# Every bad line follows a valid line: no partial exports or child launch.
while IFS='|' read -r key mapping; do
    printf 'Good=SECRET\n%b\n' "$mapping" > "$store/projects/demo/map"
    for command in env run; do
        case $command in
            env) set -- env --project demo ;;
            run) set -- run --project demo -- dash -c 'touch child-ran' ;;
        esac
        if "$ENVY_BIN" "$@" > invalid.out 2> invalid.err; then
            fail 'invalid mapping was accepted'
        fi
        [ ! -s invalid.out ] || fail 'invalid mapping emitted partial stdout'
        [ ! -e child-ran ] || fail 'invalid mapping launched a child'
        grep -F "$store/projects/demo/map:2: $key:" invalid.err > /dev/null || fail 'mapping error lacks file, line and key'
    done
done <<'INVALID'
Alias|Alias =SECRET
Alias|Alias= SECRET
Alias| Alias=SECRET
Alias|Alias=SECRET\040
Alias|Alias=SECRET # inline
SECRET|SECRET # inline
bad|bad-name=SECRET
9bad|9bad=SECRET
Alias|Alias=lower
Alias|Alias=9SECRET
Alias|Alias=BAD-NAME
Alias|Alias=
Alias|Alias=SECRET=SECRET
ENVY_STATE|ENVY_STATE=SECRET
_ENVY_PRIVATE|_ENVY_PRIVATE=SECRET
ENVY_SECRET|ENVY_SECRET
Alias|Alias=__literal__("deferred")
Alias|Alias=MISSING
lower|lower
(invalid key)|=SECRET
(invalid key)|@bad=SECRET
Alias|Alias=SECRET#comment
INVALID
for mapping in 'Alias=SECRET	' '\tAlias=SECRET' ' \t' '\rAlias=SECRET' 'Alias=SECRET\r'; do
    printf 'Good=SECRET\n%b\n' "$mapping" > "$store/projects/demo/map"
    if "$ENVY_BIN" env --project demo > invalid.out 2> invalid.err; then
        fail 'mapping whitespace was accepted'
    fi
    [ ! -s invalid.out ] || fail 'whitespace error emitted exports'
    grep -F "$store/projects/demo/map:2:" invalid.err > /dev/null || fail 'whitespace error lacks location'
done
# Even an overwritten missing reference is an error.
printf 'Alias=MISSING\nAlias=SECRET\n' > "$store/projects/demo/map"
if "$ENVY_BIN" env --project demo > invalid.out 2> invalid.err; then
    fail 'last-wins merge concealed a missing reference'
fi
[ ! -s invalid.out ] || fail 'overwritten missing reference printed stdout'

git -C "$store" checkout -- projects/demo/map
# Cached reads do not contact an unreachable store remote.
git -C "$store" remote set-url origin "$HOME/absent.git"
"$ENVY_BIN" env --project demo > offline-exports 2> offline.err
[ ! -s offline.err ] || fail 'mapping read contacted the remote'
"$ENVY_BIN" run --project demo -- dash -c 'exit 0'

# Decryption failure also holds back all output and command execution.
printf 'First=SECRET\nSecond=_SECOND\n' > "$store/projects/demo/map"
cp "$store/secrets/_SECOND.age" saved.age
printf '%s\n' 'invalid encrypted fixture' > "$store/secrets/_SECOND.age"
for command in env run; do
    case $command in
        env) set -- env --project demo ;;
        run) set -- run --project demo -- dash -c 'touch child-ran' ;;
    esac
    if "$ENVY_BIN" "$@" > decrypt.out 2> decrypt.err; then
        fail 'corrupt secret was accepted'
    fi
    [ ! -s decrypt.out ] && [ ! -e child-ran ] || fail 'decryption failure loaded partial environment'
    grep 'could not decrypt secret: _SECOND' decrypt.err > /dev/null || fail 'decryption failure not diagnosed'
done
mv saved.age "$store/secrets/_SECOND.age"
git -C "$store" checkout -- projects/demo/map

# Identity validation still precedes mapping decryption and command execution.
mv "$XDG_DATA_HOME/envy/identity" "$XDG_DATA_HOME/envy/saved-identity"
age-keygen -o "$XDG_DATA_HOME/envy/identity" > /dev/null 2>&1
for command in env run; do
    case $command in
        env) set -- env --project demo ;;
        run) set -- run --project demo -- dash -c 'touch child-ran' ;;
    esac
    if "$ENVY_BIN" "$@" > identity.out 2> identity.err; then
        fail 'environment command accepted a mismatched identity'
    fi
    [ ! -s identity.out ] || fail 'mismatched identity emitted stdout'
    [ ! -e child-ran ] || fail 'mismatched identity launched a child'
    grep 'run envy unlock' identity.err > /dev/null || fail 'identity mismatch lacks recovery instruction'
done
mv "$XDG_DATA_HOME/envy/saved-identity" "$XDG_DATA_HOME/envy/identity"

for args in 'env' 'env --project' 'env demo' 'env --project absent' 'env --project demo extra' \
    'run' 'run --project' 'run --project demo' 'run --project demo --' 'run --project demo dash' \
    'run --project ../escape -- true' 'run --project absent -- true'; do
    if printf '%s\n' "$args" | xargs "$ENVY_BIN" > args.out 2> args.err; then
        fail 'invalid environment arguments were accepted'
    fi
    [ ! -s args.out ] && [ -s args.err ] || fail 'invalid arguments did not fail quietly'
done
set -- "$XDG_DATA_HOME/envy"/.env.*
[ ! -e "$1" ] || fail 'environment command left temporary files'
