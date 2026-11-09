#!/usr/bin/env bash
# Builds dist/SpoofScope.app and dist/SpoofScope.dmg (run on macOS from the SpoofScope folder).
set -euo pipefail
rm -rf build dist
pyinstaller --noconfirm --windowed --name SpoofScope \
  --osx-bundle-identifier com.raj.SpoofScope \
  --add-data "app.py:." \
  --collect-all streamlit \
  --copy-metadata streamlit \
  --collect-submodules sklearn \
  --collect-submodules skimage.feature \
  launcher.py

APP="dist/SpoofScope.app"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$PLIST" || /usr/libexec/PlistBuddy -c "Set :LSUIElement true" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.0" "$PLIST" || true
codesign --force --deep --sign - "$APP"     # ad-hoc signature (no Apple developer account)

STAGE="build/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "SpoofScope" -srcfolder "$STAGE" -ov -format UDZO dist/SpoofScope.dmg
echo "Built dist/SpoofScope.dmg ($(du -h dist/SpoofScope.dmg | cut -f1))"
