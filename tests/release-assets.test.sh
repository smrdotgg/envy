#!/bin/sh
set -eu
. "$TEST_ROOT/tests/fixtures.sh"

# Exercise the staging CLI with a throwaway checkout; no tags or releases.
release_cli=$TEST_ROOT/.github/scripts/release-assets.sh
mkdir checkout
cd checkout
git -c init.defaultBranch=main init --quiet
git config user.name 'Release Test'
git config user.email 'release-test@example.invalid'
cp "$ENVY_BIN" envy
cp "$TEST_ROOT/install.sh" install.sh
git add envy install.sh
git commit --quiet -m 'release fixture'
version=$(sh ./envy version)
tag=v${version#envy }

sh "$release_cli" "$tag" "$HOME/assets" > stage.out 2> stage.err
[ ! -s stage.err ] || fail 'valid release wrote to stderr'
cmp envy "$HOME/assets/envy" || fail 'envy asset bytes changed'
cmp install.sh "$HOME/assets/install.sh" || fail 'installer asset bytes changed'
set -- "$HOME/assets"/*
[ "$#" -eq 2 ] || fail 'release has unexpected asset names'
grep 'staged unchanged envy and install.sh' stage.out > /dev/null || fail 'staging lacks confirmation'

for bad_tag in v999.0.0 "${tag#v}" ''; do
    if sh "$release_cli" "$bad_tag" "$HOME/refused" > mismatch.out 2> mismatch.err; then
        fail 'mismatched tag accepted'
    fi
    grep 'does not match ENVY_VERSION' mismatch.err > /dev/null || fail 'mismatch lacks diagnostic'
    [ ! -e "$HOME/refused" ] || fail 'mismatch staged assets'
done

# Metadata is inspected without evaluating candidate shell code.
for invalid in missing duplicate malformed; do
    case $invalid in
        missing) sed '/^ENVY_VERSION=/d' "$ENVY_BIN" > envy ;;
        duplicate) cat "$ENVY_BIN" > envy; printf '\nENVY_VERSION=9.0\n' >> envy ;;
        malformed)
            sed '/^ENVY_VERSION=/d' "$ENVY_BIN" > envy
            cat >> envy <<'INVALID'
ENVY_VERSION=$(touch "$HOME/executed")
INVALID
            ;;
    esac
    if sh "$release_cli" "$tag" "$HOME/refused" > metadata.out 2> metadata.err; then
        fail 'invalid version metadata accepted'
    fi
    grep 'invalid ENVY_VERSION metadata' metadata.err > /dev/null || fail 'metadata lacks diagnostic'
    [ ! -e "$HOME/refused" ] || fail 'invalid metadata staged assets'
    [ ! -e "$HOME/executed" ] || fail 'metadata executed shell code'
done

# Refuse modified scripts instead of publishing untested bytes.
for file in envy install.sh; do
    cp "$ENVY_BIN" envy
    cp "$TEST_ROOT/install.sh" install.sh
    printf '\n# changed after checkout\n' >> "$file"
    if sh "$release_cli" "$tag" "$HOME/changed" > changed.out 2> changed.err; then
        fail 'modified release file accepted'
    fi
    grep 'differs from the checked-out commit' changed.err > /dev/null || fail 'modified file lacks diagnostic'
done

# A bumped release version needs no rewrite of tests or distribution files.
sed 's/^ENVY_VERSION=.*/ENVY_VERSION=0.1.0/' "$ENVY_BIN" > envy
cp "$TEST_ROOT/install.sh" install.sh
git add envy install.sh
git commit --quiet --allow-empty -m 'release version fixture'
sh "$release_cli" v0.1.0 "$HOME/bumped" > bumped.out
cmp envy "$HOME/bumped/envy" || fail 'bumped release changed bytes'
cmp install.sh "$HOME/bumped/install.sh" || fail 'bumped installer changed bytes'

if sh "$release_cli" v0.1.0 > args.out 2> args.err; then fail 'missing destination accepted'; fi
grep 'usage:' args.err > /dev/null || fail 'missing staging usage'
