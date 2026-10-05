#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

python3 "$TEST_ROOT/tests/pty-helper.py" -- "$ENVY_BIN" init "$TEST_REMOTE" <<'RESPONSES'
throwaway-layer-passphrase
throwaway-layer-passphrase
RESPONSES
store=$XDG_DATA_HOME/envy/store

# Stores from earlier slices have no global file or projects directory.
"$ENVY_BIN" env > exports
"$ENVY_BIN" project show --global > global-map
"$ENVY_BIN" check > check.out 2> check.err
[ ! -s exports ] && [ ! -s global-map ] && [ ! -s check.out ] && [ ! -s check.err ] || fail 'empty store did not resolve or validate cleanly'
"$ENVY_BIN" run -- dash -c 'exit 29' && status=0 || status=$?
assert_equal "$status" 29 'global-only run did not preserve child status'

cat > "$HOME/editor" <<'EDITOR'
#!/bin/sh
cp "$HOME/map-input" "$1"
EDITOR
chmod +x "$HOME/editor"
EDITOR=$HOME/editor
export EDITOR

# Literal text is copied exactly, without interpreting shell syntax or escapes.
# Include empty text, whitespace, equals signs, single quotes, and final slashes.
while IFS= read -r text; do
    printf '%s' "$text" > expected-value
    printf 'Literal=__literal__("%s")\n' "$text" > "$HOME/map-input"
    "$ENVY_BIN" project edit literal
    "$ENVY_BIN" env --project literal > exports 2> valid.err
    [ ! -s valid.err ] || fail 'valid literal produced a diagnostic'
    cat exports > evaluate.sh
    printf '\nprintf "%%s" "$Literal"\n' >> evaluate.sh
    dash evaluate.sh > evaluated
    cmp expected-value evaluated || fail 'env changed literal bytes'
    printf 'printf "%%s" "$Literal"\n' > observe.sh
    "$ENVY_BIN" run --project literal -- dash observe.sh > child-value
    cmp expected-value child-value || fail 'run changed literal bytes'
    [ ! -e literal-executed ] || fail 'literal text executed shell syntax'
done <<'LITERALS'

ordinary
words separated by spaces
left=right==
# not an inline comment
$HOME ${HOME} $(touch literal-executed) `touch literal-executed`
'single quotes'; touch literal-executed
\n\t\r\\
ends with a slash\
.leading and trailing.
LITERALS
# Spaces and tabs at either end survive the resolver table and shell read.
printf '  \ttext\t\t  ' > expected-value
printf 'Literal=__literal__("  \ttext\t\t  ")\n' > "$HOME/map-input"
"$ENVY_BIN" project edit literal
"$ENVY_BIN" env --project literal > exports
cat exports > evaluate.sh
printf '\nprintf "%%s" "$Literal"\n' >> evaluate.sh
dash evaluate.sh > evaluated
cmp expected-value evaluated || fail 'env trimmed literal tabs'
"$ENVY_BIN" run --project literal -- dash observe.sh > child-value
cmp expected-value child-value || fail 'run trimmed literal tabs'

# Global edits follow the same validate-before-save and commit/push flow.
printf '%s' 'throwaway first layer value' | "$ENVY_BIN" set FIRST
printf '%s' 'throwaway second layer value' | "$ENVY_BIN" set SECOND
printf '%s' 'throwaway unused layer value' | "$ENVY_BIN" set UNUSED
cat > "$HOME/map-input" <<'GLOBAL'
# common environment
Shared=FIRST
Shared=__literal__("global last")
GlobalOnly=FIRST
Text=__literal__("UNUSED")
Empty=__literal__("")
GLOBAL
"$ENVY_BIN" project edit --global > edit.out 2> edit.err
[ ! -s edit.out ] && [ ! -s edit.err ] || fail 'global edit produced output'
"$ENVY_BIN" project show --global > global-map
cmp "$HOME/map-input" global-map || fail 'global show changed the map'
git --git-dir="$TEST_REMOTE" show HEAD:global > remote-global
cmp global-map remote-global || fail 'global edit was not pushed'
assert_equal "$(git -C "$store" log -1 --format=%s)" 'project edit --global' 'global edit commit subject'
assert_equal "$(git -C "$store" diff-tree --no-commit-id --name-only -r HEAD)" global 'global edit staged unrelated files'
revision=$(git -C "$store" rev-parse HEAD)
"$ENVY_BIN" project edit --global
assert_equal "$(git -C "$store" rev-parse HEAD)" "$revision" 'unchanged global edit made a commit'
"$ENVY_BIN" project ls > projects.out
assert_equal "$(cat projects.out)" literal 'global mapping appeared in project list'

# No selected project still receives every global alias.
cat > observe-global.sh <<'CHILD'
#!/bin/sh
set -eu
[ "$Shared" = 'global last' ]
[ "${Empty+x}" = x ] && [ "$Empty" = '' ]
[ "$Text" = UNUSED ]
printf '%s' "$GlobalOnly" > global-value
CHILD
"$ENVY_BIN" run -- dash observe-global.sh
"$ENVY_BIN" get FIRST > expected-first
cmp expected-first global-value || fail 'run without a project omitted global secret'
"$ENVY_BIN" env > exports
cat exports observe-global.sh > evaluate.sh
dash evaluate.sh
cmp expected-first global-value || fail 'env without a project omitted global secret'

# Last assignments win within each file and across the global/project boundary,
# including changing an alias from a secret to literal and back.
cat > "$HOME/map-input" <<'PROJECT'
Shared=__literal__("project first")
Shared=SECOND
GlobalOnly=__literal__("project literal")
ProjectOnly=FIRST
PROJECT
"$ENVY_BIN" project edit demo
cat > observe-layers.sh <<'CHILD'
#!/bin/sh
set -eu
[ "$GlobalOnly" = 'project literal' ]
[ "$Text" = UNUSED ]
[ "${Empty+x}" = x ] && [ "$Empty" = '' ]
printf '%s' "$Shared" > merged-shared
printf '%s' "$ProjectOnly" > merged-project
CHILD
"$ENVY_BIN" run --project demo -- dash observe-layers.sh
"$ENVY_BIN" get SECOND > expected-second
cmp expected-second merged-shared || fail 'project secret did not override global literal'
cmp expected-first merged-project || fail 'project alias was omitted'
"$ENVY_BIN" env --project demo > exports
assert_equal "$(grep -c '^export Shared=' exports)" 1 'layers emitted duplicate alias'
cat exports observe-layers.sh > evaluate.sh
dash evaluate.sh
cmp expected-second merged-shared || fail 'env merged layers differently from run'

# Editing errors do not replace the global file or alter local/remote history.
# Every malformed literal is rejected, including quotes preceded by a slash.
revision_after_project=$(git -C "$store" rev-parse HEAD)
while IFS= read -r mapping; do
    printf 'Good=FIRST\n%s\n' "$mapping" > "$HOME/map-input"
    if "$ENVY_BIN" project edit --global > invalid.out 2> invalid.err; then
        fail 'invalid global literal was saved'
    fi
    [ ! -s invalid.out ] || fail 'invalid global edit emitted stdout'
    grep -F "$store/global:2: Bad:" invalid.err > /dev/null || fail 'global edit error lacks location and alias'
    assert_equal "$(git -C "$store" rev-parse HEAD)" "$revision_after_project" 'invalid global edit changed history'
    assert_equal "$(git --git-dir="$TEST_REMOTE" rev-parse HEAD)" "$revision_after_project" 'invalid global edit changed remote history'
    "$ENVY_BIN" project show --global > after-invalid
    cmp global-map after-invalid || fail 'invalid global edit replaced map'
done <<'INVALID'
Bad=__literal__()
Bad=__literal__(text)
Bad=__literal__('text')
Bad=__literal__("text"
Bad=__literal__"text")
Bad=__literal__("text")extra
Bad=__literal__("text") # inline
Bad=__literal__( "text")
Bad=__literal__("text" )
Bad=__literal__("a"b")
Bad=__literal__("a\"b")
Bad=__literal__("a""b")
Bad= __literal__("text")
Bad =__literal__("text")
Bad=__literal__("text")=FIRST
INVALID

# A broken earlier layer is never hidden by a later assignment, and failures
# emit no exports or launch a child, even when the other layer is valid.
for broken in global projects/demo/map; do
    cp "$store/$broken" saved-map
    printf 'Shared=MISSING\nShared=__literal__("overwritten")\n' > "$store/$broken"
    for command in env run; do
        case $command in
            env) set -- env --project demo ;;
            run) set -- run --project demo -- dash -c 'touch child-ran' ;;
        esac
        if "$ENVY_BIN" "$@" > invalid.out 2> invalid.err; then
            fail 'an overwritten missing reference was ignored across layers'
        fi
        [ ! -s invalid.out ] && [ ! -e child-ran ] || fail 'invalid layer loaded part of the environment'
        grep -F "$store/$broken:1: Shared: secret not found: MISSING" invalid.err > /dev/null || fail 'layer failure lacks location'
    done
    mv saved-map "$store/$broken"
done

# check scans the whole store, needs no decryption, and counts references before
# last-wins merging. Literal text matching a secret name does not reference it.
cp "$store/secrets/FIRST.age" saved-secret.age
printf 'not ciphertext\n' > "$store/secrets/FIRST.age"
"$ENVY_BIN" check > check.out 2> check.err
printf '%s\n' 'envy: unreferenced secret: UNUSED' > expected-check
cmp expected-check check.out || fail 'check confused literal text with a secret reference'
[ ! -s check.err ] || fail 'valid check tried to decrypt a value'
mv saved-secret.age "$store/secrets/FIRST.age"

# Only overwritten references to FIRST and SECOND remain; both still count.
cp "$store/global" saved-global
cp "$store/projects/demo/map" saved-demo
cat > "$store/global" <<'GLOBAL'
Reference=SECOND
Reference=__literal__("UNUSED")
GLOBAL
cat > "$store/projects/demo/map" <<'PROJECT'
Reference=FIRST
Reference=__literal__("nothing")
PROJECT
"$ENVY_BIN" check > check.out 2> check.err
cmp expected-check check.out || fail 'check omitted overwritten references'
[ ! -s check.err ] || fail 'check rejected valid duplicate aliases'

# Keep scanning after a broken global mapping and after a broken project.
cat > "$store/global" <<'GLOBAL'
Reference=SECOND
Bad=__literal__("bad"quote")
Missing=MISSING_GLOBAL
GLOBAL
cat > "$store/projects/demo/map" <<'PROJECT'
Reference=FIRST
Bad=__literal__(notquoted)
Missing=MISSING_DEMO
PROJECT
cp "$store/projects/literal/map" saved-literal
cat > "$store/projects/literal/map" <<'PROJECT'
ENVY_RESERVED=FIRST
Missing=MISSING_LITERAL
PROJECT
if "$ENVY_BIN" check > check.out 2> check.err; then
    fail 'check succeeded with invalid mappings'
fi
cmp expected-check check.out || fail 'check did not list unused secrets alongside errors'
assert_equal "$(wc -l < check.err | tr -d ' ')" 6 'check did not report every invalid line'
for location in global:2:Bad global:3:Missing projects/demo/map:2:Bad \
    projects/demo/map:3:Missing projects/literal/map:1:ENVY_RESERVED projects/literal/map:2:Missing; do
    key=${location##*:}
    location=${location%:*}
    grep -F "$store/$location: $key:" check.err > /dev/null || fail 'check omitted a file, line or key'
done
grep -F 'bad"quote' check.err > /dev/null && fail 'check exposed arbitrary malformed text'
mv saved-global "$store/global"
mv saved-demo "$store/projects/demo/map"
mv saved-literal "$store/projects/literal/map"

# Reads stay local, and check makes no commits or changes to the store.
git -C "$store" remote set-url origin "$HOME/absent.git"
"$ENVY_BIN" env > exports 2> offline.err
"$ENVY_BIN" run -- dash observe-global.sh
"$ENVY_BIN" check > check.out 2> check.err
cmp expected-check check.out || fail 'offline check changed the result'
[ ! -s offline.err ] && [ ! -s check.err ] || fail 'layered reads contacted the remote'
assert_equal "$(git -C "$store" rev-parse HEAD)" "$revision_after_project" 'check changed store history'
assert_equal "$(git -C "$store" status --porcelain)" '' 'layer commands left a dirty store'

# Split only the fixed argument table below, with pathname expansion disabled.
set -f
for args in 'project show --global extra' 'project edit --global extra' 'project rm --global' \
    'check extra' 'env --global' 'run --'; do
    # Intentional splitting of the fixed table above; globbing is disabled.
    # shellcheck disable=SC2086
    set -- $args
    if "$ENVY_BIN" "$@" > args.out 2> args.err; then
        fail 'invalid global/check arguments were accepted'
    fi
    [ ! -s args.out ] && [ -s args.err ] || fail 'argument refusal lacks diagnostic'
done
set +f
# Later --project arguments belong to the child command.
"$ENVY_BIN" run -- dash -c '[ "$1" = extra ] && [ "$2" = --project ] && [ "$3" = demo ]' child extra --project demo
set -- "$XDG_DATA_HOME/envy"/.project.* "$XDG_DATA_HOME/envy"/.env.* "$XDG_DATA_HOME/envy"/.check.*
for path do
    [ ! -e "$path" ] || fail 'layer command left temporary files'
done
