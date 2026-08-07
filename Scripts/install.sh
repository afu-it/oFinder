#!/bin/bash
# install.sh — put the built app into /Applications, in place.
#
# Deliberately not `rm -rf` followed by `cp`. Deleting the bundle and creating
# a new one gives it a new identity on disk, and any TCC permission — Full Disk
# Access above all — is left pointing at a bundle that no longer exists. The
# permission then shows as granted in System Settings while the running app has
# none of it, which is the most confusing failure of the two.
#
# ditto overwrites the contents and leaves the bundle itself in place.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=".build/oFinder.app"
DST="/Applications/oFinder.app"

if [[ ! -d "$SRC" ]]; then
    echo "error: $SRC not found – run Scripts/bundle.sh first" >&2
    exit 1
fi

# Quit first: a running app holds its executable, and replacing it underneath
# leaves the old code running until the next launch.
killall ofinder 2>/dev/null || true
sleep 1

ditto "$SRC" "$DST"
xattr -dr com.apple.quarantine "$DST" 2>/dev/null || true

echo "installed: $DST"
codesign -d -r- "$DST" 2>&1 | grep designated || true
