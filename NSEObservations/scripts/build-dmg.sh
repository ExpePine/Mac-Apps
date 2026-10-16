#!/bin/bash
# Builds "NSE Observations.app" (Release, universal arm64 + x86_64, ad-hoc signed)
# and packages it as dist/NSEObservations.dmg.
# Requires: macOS with Xcode, and XcodeGen (brew install xcodegen). Run from anywhere.
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT="NSEObservations"
APP_NAME="NSE Observations"
BUILD_DIR="build"
OUT_DIR="dist"

if [ -f Resources/nse_equities.csv ]; then
  ROWS=$(($(wc -l < Resources/nse_equities.csv) - 1))
  echo "::notice title=NSE symbol list::bundled Resources/nse_equities.csv with ${ROWS} rows"
else
  echo "::warning title=NSE symbol list::Resources/nse_equities.csv not found; app will rely on refreshing from NSE"
fi

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building $APP_NAME (Release, universal)"
xcodebuild \
  -project "$PROJECT.xcodeproj" \
  -scheme "$PROJECT" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  -destination "generic/platform=macOS" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  build > build.log 2>&1 || {
    echo "Build failed. Compiler errors:"
    grep -E "error:" build.log | sort -u | head -80 | while IFS= read -r line; do
      echo "::error::${line}"
    done
    exit 1
  }
# Surface compiler warnings from our own sources as annotations (visible in the Actions summary)
grep -E "/Sources/.*warning:" build.log | sort -u | head -30 | while IFS= read -r line; do
  echo "::warning::${line##*/Sources/}"
done || true
tail -n 5 build.log

APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "Build failed: $APP not found"; exit 1; }

echo "==> Architectures"
ARCHS_FOUND="$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
echo "$ARCHS_FOUND"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
ICON="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$APP/Contents/Info.plist" 2>/dev/null || echo 'none')"

echo "==> Checking signature"
codesign --verify --verbose "$APP"
ENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -oE 'com\.apple\.security\.[a-z.-]+' | tr '\n' ' ' || true)"
echo "::notice title=App bundle::archs: ${ARCHS_FOUND} | min macOS: ${MIN_OS} | icon: ${ICON} | entitlements: ${ENTS}"

echo "==> Creating DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"     # drag-to-install shortcut
mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/$PROJECT.dmg"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$OUT_DIR/$PROJECT.dmg"
rm -rf "$STAGE"

echo "==> Done: $OUT_DIR/$PROJECT.dmg"
