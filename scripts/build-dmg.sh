#!/bin/bash
# Builds ActivityLogger.app (Release, ad-hoc signed) and packages it as dist/ActivityLogger.dmg
# Requires: macOS with Xcode installed, and XcodeGen (brew install xcodegen)
set -euo pipefail

cd "$(dirname "$0")/.."
NAME="ActivityLogger"
BUILD_DIR="build"
OUT_DIR="dist"

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building $NAME (Release)"
xcodebuild \
  -project "$NAME.xcodeproj" \
  -scheme "$NAME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  build | tail -n 20

APP="$BUILD_DIR/Build/Products/Release/$NAME.app"
[ -d "$APP" ] || { echo "Build failed: $APP not found"; exit 1; }

echo "==> Checking signature"
codesign --verify --verbose "$APP"

echo "==> Creating DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"     # drag-to-install shortcut
mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/$NAME.dmg"
hdiutil create -volname "Activity Logger" -srcfolder "$STAGE" -ov -format UDZO "$OUT_DIR/$NAME.dmg"
rm -rf "$STAGE"

echo "==> Done: $OUT_DIR/$NAME.dmg"
