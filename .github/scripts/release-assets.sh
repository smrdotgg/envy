#!/bin/sh
# Run from the checkout root, after the gate. Never rewrite release bytes.
set -eu

if [ "$#" -ne 2 ]; then
    printf 'usage: release-assets.sh <v-tag> <output-directory>\n' >&2
    exit 1
fi
release_tag=$1
release_output=$2
release_version=$(awk '
    /^ENVY_VERSION=/ {
        count++
        if ($0 ~ /^ENVY_VERSION=[0-9][0-9A-Za-z.+-]*$/)
            version = substr($0, 14)
    }
    END { if (count != 1 || version == "") exit 1; print version }
' envy) || {
    printf 'release: invalid ENVY_VERSION metadata\n' >&2
    exit 1
}
if [ "$release_tag" != "v$release_version" ]; then
    printf 'release: tag %s does not match ENVY_VERSION %s\n' "$release_tag" "$release_version" >&2
    exit 1
fi

mkdir -p "$release_output"
for release_file in envy install.sh; do
    git show "HEAD:$release_file" > "$release_output/$release_file"
    cmp "$release_file" "$release_output/$release_file" || {
        printf 'release: %s differs from the checked-out commit\n' "$release_file" >&2
        exit 1
    }
done
printf 'release: staged unchanged envy and install.sh for %s\n' "$release_tag"
