#!/bin/sh
# Keep the pinned CodeEditLanguages release without years of binary archives.
set -eu

packages=$(cd "${1:?Pass the SourcePackages directory}" && pwd)
set -- "$packages"/repositories/CodeEditLanguages-*
if [ "$#" -ne 1 ]; then
    echo "Expected a single CodeEditLanguages repository" >&2
    exit 1
fi
[ -d "$1" ] || exit 0
repository=$1
revision=$(git -C "$packages/checkouts/CodeEditLanguages" rev-parse HEAD)
tag=$(git -C "$repository" tag --points-at "$revision" | sed -n '1p')
if [ -z "$tag" ]; then
    echo "Cannot compact CodeEditLanguages: $revision has no release tag" >&2
    exit 1
fi

staging=$(mktemp -d "$packages/.compact.XXXXXX")
trap 'rm -rf "$staging"' EXIT
git clone --bare --depth 1 --branch "$tag" "file://$repository" "$staging/shallow"
test "$(git -C "$staging/shallow" rev-parse HEAD)" = "$revision"
# Keep SwiftPM's upstream URL and mirror configuration. Its checkout still points
# to the same alternate object store and the lockfile pins the same revision.
cp "$repository/config" "$staging/shallow/config"
mv "$repository" "$staging/original"
if ! mv "$staging/shallow" "$repository"; then
    mv "$staging/original" "$repository"
    exit 1
fi
du -sh "$repository"
