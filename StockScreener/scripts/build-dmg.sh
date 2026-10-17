#!/usr/bin/env bash
# Builds "Stock Screener.app" (universal: Apple Silicon + Intel) and packs it into a DMG.
# Usage: scripts/build-dmg.sh [version] [build-number]
# Runs on macOS with Xcode installed (GitHub's macOS runners have it).
set -euo pipefail

APP_NAME="Stock Screener"
EXEC_NAME="StockScreener"
VERSION="${1:-0.1.0}"
BUILD_NUMBER="${2:-1}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Compiling (release, universal)"
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

DIST="$ROOT/dist"
rm -rf "$DIST"
mkdir -p "$DIST"
APP="$DIST/$APP_NAME.app"

echo "==> Assembling $APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXEC_NAME" "$APP/Contents/MacOS/$EXEC_NAME"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" \
    "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"

if [ -d "$ROOT/Resources/AppIcon.iconset" ]; then
    iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> Ad-hoc signing (no Apple Developer account)"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"
lipo -info "$APP/Contents/MacOS/$EXEC_NAME"

echo "==> Creating DMG"
STAGING="$DIST/dmg-staging"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
DMG="$DIST/StockScreener-$VERSION.dmg"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

echo "==> Done: $DMG"
