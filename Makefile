.PHONY: xcode-generate xcode-build xcode-run test accuracy clean

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

# 실제 모델을 호출하는 정확도 측정(API 비용 발생). 사용 예: ICAPTURE_ACCURACY=1 ANTHROPIC_API_KEY=... make accuracy
# 결과는 build/accuracy-report.md. ICAPTURE_ACCURACY=1이 없으면 건너뛴다. NATIV_MODEL을 주면 Nativ도 측정한다.
accuracy: xcode-generate
	xcodebuild test -project iCapture.xcodeproj -scheme iCaptureAccuracy -destination 'platform=macOS,arch=arm64' -derivedDataPath $(XCODE_DERIVED_DATA)

clean:
	rm -rf build
