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

RAW_VERSION="${VERSION:-$(git describe --tags --always 2>/dev/null || echo 0.0.0-dev)}"
VERSION="${RAW_VERSION#v}"
if ! /usr/bin/printf '%s' "$VERSION" | grep -Eq '^[0-9]+(\.[0-9]+){1,2}$'; then
    VERSION="0.0.0"
fi
BUILD_NUMBER="${BUILD_NUMBER:-0}"
case "$BUILD_NUMBER" in
    ''|*[!0-9]*) BUILD_NUMBER=0 ;;
esac

mkdir -p "$BUILD_OUT"

swift build -c "$CONFIG" --scratch-path "$SCRATCH"
BIN_PATH="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/TriCup" "$APP/Contents/MacOS/TriCup"
cp "$BIN_PATH/TriCupHelper" "$APP/Contents/MacOS/TriCupHelper"
if [ ! -f "$APP/Contents/MacOS/TriCupHelper" ]; then
    echo "error: TriCupHelper missing from bundle" >&2
    exit 1
fi

# Copy menu-bar icons and app icon directly into Contents/Resources. The app
# loads these via Bundle.main (NOT Bundle.module), so no SwiftPM resource bundle
# is produced or copied.
cp "$ROOT/Resources/empty.png" "$APP/Contents/Resources/empty.png"
cp "$ROOT/Resources/half.png" "$APP/Contents/Resources/half.png"
cp "$ROOT/Resources/full.png" "$APP/Contents/Resources/full.png"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

sed -e "s/__VERSION__/${VERSION}/g" \
    -e "s/__BUILD__/${BUILD_NUMBER}/g" \
    "$ROOT/Info.plist" > "$APP/Contents/Info.plist"

# Integrity check: catch packaging regressions before signing.
for required in \
    "Contents/MacOS/TriCup" \
    "Contents/MacOS/TriCupHelper" \
    "Contents/Info.plist" \
    "Contents/Resources/empty.png" \
    "Contents/Resources/half.png" \
    "Contents/Resources/full.png" \
    "Contents/Resources/AppIcon.icns"
do
    if [ ! -e "$APP/$required" ]; then
        echo "error: missing $required" >&2
        exit 1
    fi
done

# Ad-hoc sign nested executables first, then the bundle, then verify.
codesign --force --sign - "$APP/Contents/MacOS/TriCupHelper"
codesign --force --sign - "$APP/Contents/MacOS/TriCup"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

ZIP="$BUILD_OUT/TriCup.app.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# Verify the produced zip is intact and contains the app bundle.
if ! unzip -t "$ZIP" >/dev/null 2>&1; then
    echo "error: zip integrity check failed" >&2
    exit 1
fi
if ! unzip -l "$ZIP" | grep -q "TriCup.app/Contents/MacOS/TriCup"; then
    echo "error: zip missing TriCup executable" >&2
    exit 1
fi

echo "Built app: $APP"
echo "Artifact:  $ZIP"
