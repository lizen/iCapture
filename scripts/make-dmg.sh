#!/bin/bash
# Builds a DMG for your own Macs (not notarized).
# Builds Release and packages iCapture.app with an Applications shortcut as build/iCapture-<version>.dmg.
# Signs with the Apple Development certificate from Configuration/Signing.xcconfig as is.
# Distributing to other people additionally requires Developer ID signing and notarization (notarytool).
# Usage: make dmg   (run from the repository root; make runs xcodegen generate first)

set -euo pipefail

fail() {
    echo "error: $*" >&2
    exit 1
}

derived_data="${XCODE_DERIVED_DATA:-build/DerivedData.noindex}"
app="$derived_data/Build/Products/Release/iCapture.app"
staging="build/dmg.noindex"

xcodebuild -project iCapture.xcodeproj -scheme iCapture -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived_data" build -quiet
[[ -d "$app" ]] || fail "빌드된 앱이 없어요: $app"

# Verify first so a broken signature never gets packaged.
codesign --verify --deep --strict "$app" || fail "앱 서명을 확인하지 못했어요: $app"
authority="$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
[[ -n "$version" ]] || fail "앱 버전(CFBundleShortVersionString)을 읽지 못했어요"
dmg="build/iCapture-$version.dmg"

rm -rf "$staging"
mkdir -p "$staging"
ditto "$app" "$staging/iCapture.app"
ln -s /Applications "$staging/Applications"

hdiutil create -volname "iCapture" -srcfolder "$staging" -ov -format UDZO "$dmg" -quiet
hdiutil verify "$dmg" -quiet
rm -rf "$staging"

echo "만들었어요: $dmg ($(du -h "$dmg" | cut -f1 | tr -d ' '), 서명: ${authority:-없음})"
echo "다른 사람에게 배포하려면 Developer ID 서명과 공증이 필요해요."
