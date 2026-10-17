#!/usr/bin/env bash
# Builds TabCop.app (universal: Apple Silicon + Intel) and packs it into dist/TabCop.dmg.
# Usage: scripts/build-dmg.sh [version] [build-number]
# Runs on macOS with Xcode or the Command Line Tools installed.
set -euo pipefail

VERSION="${1:-1.0}"
BUILD_NUMBER="${2:-1}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DIST="$ROOT/dist"
rm -rf "$DIST"
mkdir -p "$DIST/obj"
APP="$DIST/TabCop.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling (release, universal)"
swiftc -O -target arm64-apple-macos13.0  TabCop.swift -o "$DIST/obj/TabCop-arm64"
swiftc -O -target x86_64-apple-macos13.0 TabCop.swift -o "$DIST/obj/TabCop-x86_64"
lipo -create "$DIST/obj/TabCop-arm64" "$DIST/obj/TabCop-x86_64" -output "$APP/Contents/MacOS/TabCop"
rm -rf "$DIST/obj"

sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" \
    "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"

echo "==> Ad-hoc signing (no Apple Developer account)"
codesign --force --sign - "$APP"
codesign --verify --verbose "$APP"
lipo -info "$APP/Contents/MacOS/TabCop"

echo "==> Creating DMG"
STAGING="$DIST/dmg-staging"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "TabCop" -srcfolder "$STAGING" -ov -format UDZO "$DIST/TabCop.dmg"
rm -rf "$STAGING"

echo "==> Done: $DIST/TabCop.dmg"
