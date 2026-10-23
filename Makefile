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

# 실제 모델을 호출하는 정확도 측정. 사용 예: ICAPTURE_ACCURACY=1 make accuracy
# 기본은 로컬 서버(Nativ·vLLM, http://127.0.0.1:8080)만 잰다(비용 없음). 결과는 build/accuracy-report.md.
# LOCAL_BASE_URL=http://127.0.0.1:8000(vLLM 등), LOCAL_MODEL=<모델 id>, LOCAL_API_KEY=<키>로 바꿀 수 있다.
# ANTHROPIC_API_KEY를 주면 Claude Sonnet·Haiku도 잰다(API 비용 발생). ICAPTURE_ACCURACY=1이 없으면 건너뛴다.
accuracy: xcode-generate
	xcodebuild test -project iCapture.xcodeproj -scheme iCaptureAccuracy -destination 'platform=macOS,arch=arm64' -derivedDataPath $(XCODE_DERIVED_DATA)

clean:
	rm -rf build
