#!/usr/bin/env bash
# Builds ResumeForge.app (universal: Apple Silicon + Intel) with its embedded Safari extension,
# ad-hoc signs it, and packs it into dist/ResumeForge.dmg.
# Usage: scripts/build-dmg.sh [version] [build-number]
# Runs on macOS with Xcode + XcodeGen (GitHub's macOS runners have Xcode; the script installs XcodeGen).
set -euo pipefail

VERSION="${1:-1.0}"
BUILD_NUMBER="${2:-1}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "==> Installing XcodeGen"
    brew install xcodegen
fi

echo "==> Generating Xcode project"
xcodegen generate --spec project.yml

DIST="$ROOT/dist"
DERIVED="$ROOT/build/DerivedData"
rm -rf "$DIST" "$DERIVED"
mkdir -p "$DIST"

echo "==> Compiling (release, universal, ad-hoc signed)"
xcodebuild \
    -project ResumeForge.xcodeproj \
    -scheme ResumeForge \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
    CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
    build

APP_SRC="$DERIVED/Build/Products/Release/ResumeForge.app"
APP="$DIST/ResumeForge.app"
cp -R "$APP_SRC" "$APP"

echo "==> Checking bundle"
APPEX="$APP/Contents/PlugIns/ResumeForgeExtension.appex"
test -d "$APPEX" || { echo "error: Safari extension was not embedded"; exit 1; }
test -f "$APPEX/Contents/Resources/manifest.json" || { echo "error: manifest.json missing from extension Resources"; ls -R "$APPEX/Contents/Resources"; exit 1; }
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APPEX" 2>/dev/null | grep -q app-sandbox || { echo "error: extension is not sandboxed"; exit 1; }
lipo -info "$APP/Contents/MacOS/ResumeForge"
lipo -info "$APPEX/Contents/MacOS/ResumeForgeExtension"

echo "==> Creating DMG"
STAGING="$DIST/dmg-staging"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "ResumeForge" -srcfolder "$STAGING" -ov -format UDZO "$DIST/ResumeForge.dmg"
rm -rf "$STAGING"

echo "==> Done: $DIST/ResumeForge.dmg"
