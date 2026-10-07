#!/bin/sh
# Download pinned, verified release assets at build time. The installed app works offline.
# After changing the Herdr version, run scripts/herdr-notices.py on a checkout of the same tag.
set -eu

task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
task_cache="$task_root/build/herdr/0.9.3"
mkdir -p "$task_cache"

fetch() {
    task_asset=$1
    task_hash=$2
    task_file="$task_cache/$task_asset"
    if [ ! -f "$task_file" ] || [ "$(shasum -a 256 "$task_file" | awk '{print $1}')" != "$task_hash" ]; then
        task_download=$(mktemp "$task_cache/download.XXXXXX")
        trap 'rm -f "$task_download"' EXIT HUP INT TERM
        curl --fail --location --retry 3 --connect-timeout 15 --max-time 180 \
            "https://github.com/herdrdev/herdr/releases/download/v0.9.3/$task_asset" -o "$task_download"
        if [ "$(shasum -a 256 "$task_download" | awk '{print $1}')" != "$task_hash" ]; then
            echo "error: Herdr checksum mismatch for $task_asset" >&2
            exit 1
        fi
        mv "$task_download" "$task_file"
        trap - EXIT HUP INT TERM
    fi
}

fetch herdr-macos-aarch64 5173a3e0ae42d5d1ab7ebfa5d5e6329f7c3d23f8e1a3677c7ce3231da2884157
fetch herdr-macos-x86_64 db62d548ff3e832b087a96b1894a08d26be3905f1830309cd556783f215d4054

if [ "${1:-}" = "--prepare" ]; then exit 0; fi
: "${TARGET_BUILD_DIR:?Run from Xcode, or use --prepare to cache the release assets}"
: "${CONTENTS_FOLDER_PATH:?Missing app bundle path}"
task_helper="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/herdr"
mkdir -p "$(dirname "$task_helper")"
lipo -create "$task_cache/herdr-macos-aarch64" "$task_cache/herdr-macos-x86_64" -output "$task_helper"
chmod 755 "$task_helper"
if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]; then
    if [ "${ENABLE_HARDENED_RUNTIME:-NO}" = "YES" ]; then
        codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime --timestamp "$task_helper"
    else
        codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$task_helper"
    fi
fi
