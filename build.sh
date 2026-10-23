#!/usr/bin/env bash
# Builds build/Rec Menu.app.
#   --install  also copy it to /Applications
#   --dmg      also package build/RecMenu-<version>.dmg
# Signing: ad-hoc by default. Set SIGN_IDENTITY="Developer ID Application: ..." to sign
# for distribution, and NOTARY_PROFILE=<notarytool keychain profile> to notarize the DMG.
set -euo pipefail
cd "$(dirname "$0")"
version=$(tr -d '[:space:]' < VERSION)
bundle_id=io.github.deepakanandrao.recmenu
out=build
app="$out/Rec Menu.app"
install=0 dmg=0
for arg in "$@"; do
  case "$arg" in
    --install) install=1;;
    --dmg) dmg=1;;
    *) echo "unknown option: $arg" >&2; exit 1;;
  esac
done

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
xcrun swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14 \
  RecMenu.swift -o "$app/Contents/MacOS/RecMenu"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Rec Menu</string>
  <key>CFBundleDisplayName</key><string>Rec Menu</string>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleExecutable</key><string>RecMenu</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Deep Anandrao. Licensed under the Apache License 2.0.</string>
</dict>
</plist>
PLIST

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$app"
else
  codesign --force --sign - "$app"
fi
echo "Built $(pwd)/$app ($version)"

if [ "$install" = 1 ]; then
  rm -rf "/Applications/Rec Menu.app"
  cp -R "$app" /Applications/
  echo "Installed /Applications/Rec Menu.app"
fi

if [ "$dmg" = 1 ]; then
  stage="$out/dmg"
  image="$out/RecMenu-$version.dmg"
  rm -rf "$stage" "$image"
  mkdir -p "$stage"
  cp -R "$app" "$stage/"
  ln -s /Applications "$stage/Applications"
  hdiutil create -quiet -volname "Rec Menu $version" -srcfolder "$stage" -fs HFS+ -format UDZO "$image"
  rm -rf "$stage"
  if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$image"
  fi
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$image" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$image"
  fi
  echo "Packaged $(pwd)/$image"
fi
