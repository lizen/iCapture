.PHONY: xcode-generate xcode-build xcode-run test clean

XCODE_DERIVED_DATA ?= build/DerivedData
ICAPTURE_APP := $(XCODE_DERIVED_DATA)/Build/Products/Debug/iCapture.app
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

xcode-generate:
	xcodegen generate

xcode-build: xcode-generate
	xcodebuild -project iCapture.xcodeproj -scheme iCapture -configuration Debug -derivedDataPath $(XCODE_DERIVED_DATA) build

xcode-run: xcode-build
	open $(ICAPTURE_APP)

# 사용 예: make test ONLY=iCaptureTests/SmokeTests
test: xcode-generate
	xcodebuild test -project iCapture.xcodeproj -scheme iCapture -destination 'platform=macOS,arch=arm64' -derivedDataPath $(XCODE_DERIVED_DATA) $(if $(ONLY),-only-testing:$(ONLY))

clean:
	rm -rf build
