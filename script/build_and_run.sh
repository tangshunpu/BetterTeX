#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="BetterTeX"
CONFIGURATION="${CONFIGURATION:-debug}"
APP_VERSION="${BETTERTEX_VERSION:-$(cat "$ROOT_DIR/VERSION")}"
BUILD_NUMBER="${BETTERTEX_BUILD_NUMBER:-$(git -C "$ROOT_DIR" rev-list --count HEAD)}"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ || ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Invalid BETTERTEX_VERSION or BETTERTEX_BUILD_NUMBER." >&2; exit 1
fi
BUILD_CACHE="${BETTERTEX_BUILD_CACHE:-$HOME/Library/Caches/BetterTeX/Build}"
APP_BUNDLE="$BUILD_CACHE/Staging/$APP_NAME.app"
DELIVERY_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
cd "$ROOT_DIR"

case "$MODE" in run|--verify|--debug|--logs|--telemetry|--build-only) ;; *) echo "Usage: $0 [--verify|--debug|--logs|--telemetry|--build-only]" >&2; exit 2;; esac

if [[ "$MODE" == "--build-only" ]] && pgrep -x "$APP_NAME" >/dev/null; then
  echo "Close BetterTeX before replacing its app bundle, or use the default build-and-run command." >&2
  exit 1
fi

if [[ "$MODE" != "--build-only" ]]; then
  # Ask the existing application to save first; do not kill unsaved buffers.
  if pgrep -x "$APP_NAME" >/dev/null; then
    osascript -e 'tell application id "dev.bettertex.app" to quit' || true
    for _ in {1..20}; do if ! pgrep -x "$APP_NAME" >/dev/null; then break; fi; sleep 0.2; done
    if pgrep -x "$APP_NAME" >/dev/null; then echo "BetterTeX is still open. Finish its save/terminal dialog and run again." >&2; exit 1; fi
  fi
fi

swift build --scratch-path "$BUILD_CACHE" -c "$CONFIGURATION"
BUILD_DIR="$(swift build --scratch-path "$BUILD_CACHE" -c "$CONFIGURATION" --show-bin-path)"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP_BUNDLE/Contents/Resources/"
if [[ ! -f "$APP_BUNDLE/Contents/Resources/BetterTeX.icns" || "$ROOT_DIR/script/make_icon.swift" -nt "$APP_BUNDLE/Contents/Resources/BetterTeX.icns" ]]; then
  swift "$ROOT_DIR/script/make_icon.swift" "$BUILD_CACHE/BetterTeX.iconset"
  iconutil -c icns "$BUILD_CACHE/BetterTeX.iconset" -o "$APP_BUNDLE/Contents/Resources/BetterTeX.icns"
fi
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/.$APP_NAME.new"
mv -f "$APP_BUNDLE/Contents/MacOS/.$APP_NAME.new" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
# Include any SwiftPM resource bundles next to the executable.
for resource in "$BUILD_DIR"/*.bundle; do
  if [[ -d "$resource" ]]; then
    resource_name="$(basename "$resource")"
    # Replace rather than merge: an earlier build may contain obsolete resources and signatures.
    rm -rf "$APP_BUNDLE/Contents/Resources/$resource_name" "$APP_BUNDLE/Contents/MacOS/$resource_name"
    cp -R "$resource" "$APP_BUNDLE/Contents/Resources/"
    cp -R "$resource" "$APP_BUNDLE/Contents/MacOS/"
  fi
done
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BetterTeX</string>
<key>CFBundleIdentifier</key><string>dev.bettertex.app</string>
<key>CFBundleName</key><string>BetterTeX</string>
<key>CFBundleDisplayName</key><string>BetterTeX</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
<key>CFBundleIconFile</key><string>BetterTeX</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>BetterTeX uses your local development tools.</string>
<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>LaTeX document</string><key>CFBundleTypeExtensions</key><array><string>tex</string><string>bib</string><string>sty</string><string>cls</string></array><key>CFBundleTypeRole</key><string>Editor</string></dict></array>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION%%[-+]*}" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :BetterTeXReleaseVersion string $APP_VERSION" "$APP_BUNDLE/Contents/Info.plist"
xattr -cr "$APP_BUNDLE"
for resource in "$APP_BUNDLE/Contents/Resources/"*.bundle "$APP_BUNDLE/Contents/MacOS/"*.bundle; do
  if [[ -d "$resource" ]]; then codesign --force --sign - "$resource" >/dev/null; fi
done
codesign --force --sign - "$APP_BUNDLE" >/dev/null
mkdir -p "$ROOT_DIR/dist"
rm -rf "$DELIVERY_BUNDLE"
ditto --norsrc "$APP_BUNDLE" "$DELIVERY_BUNDLE"
"$ROOT_DIR/script/verify_bundle.sh" "$APP_BUNDLE"
# FileProvider can attach FinderInfo asynchronously after copying. Retry cleanup briefly,
# but never deliver a bundle that still fails the resource/signature checks.
for verification_attempt in 1 2 3; do
  xattr -cr "$DELIVERY_BUNDLE"
  if "$ROOT_DIR/script/verify_bundle.sh" "$DELIVERY_BUNDLE" > "$BUILD_CACHE/bundle-verification.log" 2>&1; then break; fi
  if [[ "$verification_attempt" == 3 ]]; then cat "$BUILD_CACHE/bundle-verification.log" >&2; exit 1; fi
  sleep 0.2
done
# Keep a clean portable archive even when Documents is managed by iCloud.
ditto -c -k --norsrc --noextattr --keepParent "$APP_BUNDLE" "$ROOT_DIR/dist/BetterTeX.zip"
UPDATE_ARCHIVE="$ROOT_DIR/dist/BetterTeX-$APP_VERSION-macOS-$(uname -m).zip"
cp "$ROOT_DIR/dist/BetterTeX.zip" "$UPDATE_ARCHIVE"
# An archive rebuilt without a signing key must not retain a stale detached signature.
rm -f "$UPDATE_ARCHIVE.sig" "$ROOT_DIR/dist/BetterTeX.zip.sig"
if [[ -n "${BETTERTEX_UPDATE_SIGNING_KEY:-}" ]]; then
  swift "$ROOT_DIR/script/sign_update.swift" sign "$UPDATE_ARCHIVE" "$BETTERTEX_UPDATE_SIGNING_KEY" "$ROOT_DIR/Sources/BetterTeXCore/Resources/UpdateSigningPublicKey.txt"
  cp "$UPDATE_ARCHIVE.sig" "$ROOT_DIR/dist/BetterTeX.zip.sig"
fi
APP_BUNDLE="$DELIVERY_BUNDLE"

case "$MODE" in
  --build-only) echo "Built $APP_BUNDLE" ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs) open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "BetterTeX"' ;;
  --telemetry) open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "dev.bettertex.app"' ;;
  --verify) open -n "$APP_BUNDLE"; sleep 2; pgrep -x "$APP_NAME" >/dev/null; echo "BetterTeX launched successfully." ;;
  run) open -n "$APP_BUNDLE" ;;
esac
