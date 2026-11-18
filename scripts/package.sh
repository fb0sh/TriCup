#!/usr/bin/env bash
#
# Build TriCup, assemble a minimal .app bundle, ad-hoc sign it and produce
# TriCup.app.zip. Runs on macOS only (GitHub Actions macos-26 is the CI host).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="release"
SCRATCH="$ROOT/tmp/.build"
BUILD_OUT="$ROOT/tmp/build"
APP="$BUILD_OUT/TriCup.app"

VERSION="${VERSION:-$(git describe --tags --always 2>/dev/null || echo 0.0.0-dev)}"
BUILD_NUMBER="${BUILD_NUMBER:-0}"

mkdir -p "$BUILD_OUT"

swift build -c "$CONFIG" --scratch-path "$SCRATCH"
BIN_PATH="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/TriCup" "$APP/Contents/MacOS/TriCup"
cp "$BIN_PATH/TriCupHelper" "$APP/Contents/MacOS/TriCupHelper"

# Copy SwiftPM resource bundles (icons) next to the executable's bundle.
shopt -s nullglob
for bundle in "$BIN_PATH"/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

sed -e "s/__VERSION__/${VERSION}/g" \
    -e "s/__BUILD__/${BUILD_NUMBER}/g" \
    "$ROOT/Info.plist" > "$APP/Contents/Info.plist"

# Ad-hoc sign nested executables first, then the bundle, then verify.
codesign --force --sign - "$APP/Contents/MacOS/TriCupHelper"
codesign --force --sign - "$APP/Contents/MacOS/TriCup"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

ZIP="$BUILD_OUT/TriCup.app.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Built app: $APP"
echo "Artifact:  $ZIP"
