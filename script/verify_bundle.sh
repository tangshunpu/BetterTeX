#!/usr/bin/env bash
# Fail packaging before a user receives a bundle missing localization or update resources.
set -euo pipefail
APP_BUNDLE="${1:?Usage: verify_bundle.sh APP_BUNDLE}"
RESOURCE_ROOT="$APP_BUNDLE/Contents/Resources/BetterTeX_BetterTeXCore.bundle"
if [[ -d "$RESOURCE_ROOT/Contents/Resources" ]]; then RESOURCE_ROOT="$RESOURCE_ROOT/Contents/Resources"; fi
for name in en.lproj/Localizable.strings zh-Hans.lproj/Localizable.strings install-update.sh UpdateSigningPublicKey.txt; do
  [[ -r "$RESOURCE_ROOT/$name" ]] || { echo "Missing app resource: $name" >&2; exit 1; }
done
[[ -d "$APP_BUNDLE/Contents/Resources/SwiftTerm_SwiftTerm.bundle" ]] || { echo "Missing SwiftTerm resource bundle." >&2; exit 1; }
[[ -x "$APP_BUNDLE/Contents/MacOS/BetterTeX" ]] || { echo "Missing app executable." >&2; exit 1; }
codesign --verify --deep --strict "$APP_BUNDLE"
