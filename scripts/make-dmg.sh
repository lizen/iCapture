#!/bin/bash
# 내 맥이나 직접 옮겨 쓰는 용도의 DMG를 만든다(공증 없음).
# Release로 빌드하고, iCapture.app과 Applications 바로가기를 담아 build/iCapture-<버전>.dmg로 묶는다.
# 서명은 Configuration/Signing.xcconfig의 Apple Development 인증서를 그대로 쓴다.
# 다른 사람에게 배포하려면 Developer ID 서명과 공증(notarytool)이 따로 필요하다.
# 사용: make dmg   (저장소 루트에서 실행. xcodegen generate는 make가 먼저 돌린다)

set -euo pipefail

fail() {
    echo "error: $*" >&2
    exit 1
}

derived_data="${XCODE_DERIVED_DATA:-build/DerivedData}"
app="$derived_data/Build/Products/Release/iCapture.app"
staging="build/dmg"

xcodebuild -project iCapture.xcodeproj -scheme iCapture -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived_data" build -quiet
[[ -d "$app" ]] || fail "빌드된 앱이 없어요: $app"

# 서명이 깨진 앱을 묶지 않게 먼저 확인한다.
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
