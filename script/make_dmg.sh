#!/usr/bin/env bash
# Packages the built app as a drag-to-install disk image: dist/BetterTeX.dmg.
# Run ./script/build_and_run.sh --build-only first (usually with CONFIGURATION=release).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="BetterTeX"
BUILD_CACHE="${BETTERTEX_BUILD_CACHE:-$HOME/Library/Caches/BetterTeX/Build}"
ARCHIVE="$ROOT_DIR/dist/$APP_NAME.zip"
OUTPUT="${1:-$ROOT_DIR/dist/$APP_NAME.dmg}"
STAGE="$BUILD_CACHE/DMG"

[[ -f "$ARCHIVE" ]] || { echo "Missing $ARCHIVE. Build the app first." >&2; exit 1; }

# Start from the clean archive rather than dist/BetterTeX.app: a bundle kept under an
# iCloud-managed folder can pick up Finder attributes that break strict signature checks.
rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto -x -k "$ARCHIVE" "$STAGE"
"$ROOT_DIR/script/verify_bundle.sh" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUTPUT"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUTPUT" >/dev/null 2> >(grep -v "is deprecated" >&2)
rm -rf "$STAGE"

# (hdiutil is used instead of `diskutil image` so the script also runs on older macOS.)
# Mount the image read-only and check that the app inside is intact.
MOUNT="$(mktemp -d)"
hdiutil attach "$OUTPUT" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null 2> >(grep -v "is deprecated" >&2)
trap 'hdiutil detach "$MOUNT" >/dev/null 2>&1 || true; rmdir "$MOUNT" 2>/dev/null || true' EXIT
"$ROOT_DIR/script/verify_bundle.sh" "$MOUNT/$APP_NAME.app"
[[ -L "$MOUNT/Applications" ]]

echo "Built $OUTPUT"
