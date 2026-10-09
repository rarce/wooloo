#!/bin/sh
# Write the Sparkle feed for one release: appcast.xml with a single item for the archive, its
# release notes embedded, the archive and the feed signed with wooloo's EdDSA key. The key comes
# from SPARKLE_PRIVATE_KEY (CI) or else from the login Keychain, account "wooloo" (generate_keys).
#
#   scripts/release-appcast.sh <wooloo-X.Y.Z.zip> <notes.md> <vX.Y.Z> <output directory>
set -eu

if [ $# -ne 4 ]; then
    echo "usage: $0 <archive.zip> <notes.md> <tag> <output directory>" >&2
    exit 2
fi
task_archive=$1
task_notes=$2
task_tag=$3
task_output=$4
task_repository=${GITHUB_REPOSITORY:-rarce/wooloo}

task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
task_version=2.10.0
task_tools="$task_root/build/sparkle/$task_version"
task_tarball="$task_tools/Sparkle-$task_version.tar.xz"
task_hash=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c

# Sparkle's tools come from the release whose framework the app links (Package.resolved).
if [ ! -x "$task_tools/bin/generate_appcast" ]; then
    mkdir -p "$task_tools"
    curl --fail --location --retry 3 --connect-timeout 15 --max-time 180 \
        "https://github.com/sparkle-project/Sparkle/releases/download/$task_version/Sparkle-$task_version.tar.xz" \
        -o "$task_tarball"
    if [ "$(shasum -a 256 "$task_tarball" | awk '{print $1}')" != "$task_hash" ]; then
        echo "error: Sparkle checksum mismatch" >&2
        rm -f "$task_tarball"
        exit 1
    fi
    tar -xJf "$task_tarball" -C "$task_tools" ./bin
fi

# generate_appcast reads every archive in a folder and takes notes named like the archive.
task_work=$(mktemp -d)
trap 'rm -rf "$task_work"' EXIT HUP INT TERM
task_name=$(basename "$task_archive" .zip)
cp "$task_archive" "$task_work/$task_name.zip"
cp "$task_notes" "$task_work/$task_name.md"

set -- "$task_tools/bin/generate_appcast" \
    --download-url-prefix "https://github.com/$task_repository/releases/download/$task_tag/" \
    --link "https://github.com/$task_repository/releases/tag/$task_tag" \
    --embed-release-notes \
    "$task_work"
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$@" --ed-key-file -
else
    "$@" --account wooloo
fi

# A key that does not match the app's SUPublicEDKey only prints a warning and leaves the item
# unsigned, which every installed copy would reject.
task_feed="$task_work/appcast.xml"
if ! grep -q 'sparkle:edSignature=' "$task_feed"; then
    echo "error: the archive was not signed; does the key match SUPublicEDKey in wooloo/Info.plist?" >&2
    exit 1
fi
if ! grep -q 'sparkle-signatures:' "$task_feed"; then
    echo "error: the feed was not signed; the app requires a signed feed (SURequireSignedFeed)" >&2
    exit 1
fi
mkdir -p "$task_output"
cp "$task_feed" "$task_output/appcast.xml"
echo "Wrote $task_output/appcast.xml"
