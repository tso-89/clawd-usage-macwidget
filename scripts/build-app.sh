#!/bin/zsh
# Builds dist/Clawd Usage.app from the SwiftPM package.
#   scripts/build-app.sh            release build, ad-hoc signed
#   SIGN_ID="Developer ID Application: ..." scripts/build-app.sh   signed with hardened runtime
#   SIGN_ID=... NOTARY_PROFILE=<name> scripts/build-app.sh   also notarized and stapled, plus dist/Clawd-Usage.dmg
#     (the profile once: xcrun notarytool store-credentials <name> --apple-id ... --team-id ...)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -nE 's/.*static let version = "([^"]+)".*/\1/p' Sources/ClawdUsage/AppModel.swift)
CONFIG=${CONFIG:-release}
APP="dist/Clawd Usage.app"

swift build -c "$CONFIG" --arch arm64 --arch x86_64 2>/dev/null || swift build -c "$CONFIG"
BIN=$(swift build -c "$CONFIG" --show-bin-path 2>/dev/null)/ClawdUsage
[[ -x "$BIN" ]] || BIN=".build/apple/Products/Release/ClawdUsage"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClawdUsage"
cp -R Resources/. "$APP/Contents/Resources/"
cp CHANGELOG.md "$APP/Contents/Resources/CHANGELOG.md"
[[ -f build/AppIcon.icns ]] || swift scripts/make-icon.swift build >/dev/null
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Clawd Usage</string>
  <key>CFBundleDisplayName</key><string>Clawd Usage</string>
  <key>CFBundleIdentifier</key><string>io.github.tso-89.clawd-usage</string>
  <key>CFBundleExecutable</key><string>ClawdUsage</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT. Not affiliated with Anthropic.</string>
</dict>
</plist>
PLIST

if [[ -n "${SIGN_ID:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    # notarytool can exit 0 on a rejected submission: check the status itself.
    notarize() {
      local out
      out=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait)
      echo "$out"
      grep -q "status: Accepted" <<< "$out" || { echo "notarization failed (xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE)"; exit 1; }
    }
    ZIP="dist/Clawd-Usage-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    notarize "$ZIP"
    rm -f "$ZIP"
    xcrun stapler staple "$APP"
    # The release download: the stapled app and an Applications link to drag it onto.
    DMG="dist/Clawd-Usage.dmg"
    STAGE=$(mktemp -d)
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f "$DMG"
    hdiutil create -volname "Clawd Usage" -srcfolder "$STAGE" -format UDZO -quiet "$DMG"
    rm -rf "$STAGE"
    codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    echo "notarized: $DMG"
  fi
else
  codesign --force --sign - "$APP"
fi
echo "built $APP ($VERSION)"
