#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="BetterTeX"
CONFIGURATION="${CONFIGURATION:-debug}"
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
  if [[ -d "$resource" ]]; then cp -R "$resource" "$APP_BUNDLE/Contents/Resources/"; cp -R "$resource" "$APP_BUNDLE/Contents/MacOS/"; fi
done
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BetterTeX</string>
<key>CFBundleIdentifier</key><string>dev.bettertex.app</string>
<key>CFBundleName</key><string>BetterTeX</string>
<key>CFBundleDisplayName</key><string>BetterTeX</string>
<key>CFBundleIconFile</key><string>BetterTeX</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>BetterTeX uses your local development tools.</string>
<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>LaTeX document</string><key>CFBundleTypeExtensions</key><array><string>tex</string><string>bib</string><string>sty</string><string>cls</string></array><key>CFBundleTypeRole</key><string>Editor</string></dict></array>
</dict></plist>
PLIST
xattr -cr "$APP_BUNDLE"
codesign --force --sign - "$APP_BUNDLE" >/dev/null
mkdir -p "$ROOT_DIR/dist"
ditto --norsrc "$APP_BUNDLE" "$DELIVERY_BUNDLE"
# FileProvider may add FinderInfo to copied bundles; strip it after copying.
xattr -cr "$DELIVERY_BUNDLE"
# Keep a clean portable archive even when Documents is managed by iCloud.
ditto -c -k --norsrc --noextattr --keepParent "$APP_BUNDLE" "$ROOT_DIR/dist/BetterTeX.zip"
codesign --verify --deep --strict "$APP_BUNDLE"
APP_BUNDLE="$DELIVERY_BUNDLE"

case "$MODE" in
  --build-only) echo "Built $APP_BUNDLE" ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs) open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "BetterTeX"' ;;
  --telemetry) open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "dev.bettertex.app"' ;;
  --verify) open -n "$APP_BUNDLE"; sleep 2; pgrep -x "$APP_NAME" >/dev/null; echo "BetterTeX launched successfully." ;;
  run) open -n "$APP_BUNDLE" ;;
esac
