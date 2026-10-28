.PHONY: xcode-generate xcode-build xcode-run test accuracy dmg clean

XCODE_DERIVED_DATA ?= build/DerivedData
ICAPTURE_APP := $(XCODE_DERIVED_DATA)/Build/Products/Debug/iCapture.app
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

xcode-generate:
	xcodegen generate

xcode-build: xcode-generate
	xcodebuild -project iCapture.xcodeproj -scheme iCapture -configuration Debug -derivedDataPath $(XCODE_DERIVED_DATA) build

xcode-run: xcode-build
	open $(ICAPTURE_APP)

# Example: make test ONLY=iCaptureTests/SmokeTests
test: xcode-generate
	xcodebuild test -project iCapture.xcodeproj -scheme iCapture -destination 'platform=macOS,arch=arm64' -derivedDataPath $(XCODE_DERIVED_DATA) $(if $(ONLY),-only-testing:$(ONLY))

# Accuracy measurement that calls real models. Example: ICAPTURE_ACCURACY=1 make accuracy
# Measures only the local server (Nativ, Ollama, vLLM; http://127.0.0.1:8080) by default, at no cost. Report: build/accuracy-report.md.
# Override with LOCAL_BASE_URL=http://127.0.0.1:8000 (vLLM etc.), LOCAL_MODEL=<model id>, LOCAL_API_KEY=<key>.
# With ANTHROPIC_API_KEY, Claude Sonnet and Haiku are measured too (billed API usage). Skipped unless ICAPTURE_ACCURACY=1.
accuracy: xcode-generate
	xcodebuild test -project iCapture.xcodeproj -scheme iCaptureAccuracy -destination 'platform=macOS,arch=arm64' -derivedDataPath $(XCODE_DERIVED_DATA)

# DMG for your own Macs (Release build, Apple Development signature, not notarized). Output: build/iCapture-<version>.dmg
dmg: xcode-generate
	XCODE_DERIVED_DATA=$(XCODE_DERIVED_DATA) ./scripts/make-dmg.sh

clean:
	rm -rf build
