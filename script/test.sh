#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
BUILD_CACHE="${BETTERTEX_BUILD_CACHE:-$HOME/Library/Caches/BetterTeX/Build}"
swift test --scratch-path "$BUILD_CACHE" "$@"
