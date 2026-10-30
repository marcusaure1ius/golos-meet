.PHONY: help build test check check-rust preview-package

DERIVED_DATA ?= $(CURDIR)/.build/xcode
PREVIEW_REF ?= HEAD
PREVIEW_OUTPUT ?= $(CURDIR)/.build/preview

help:
	@echo "make check       — сборка и Swift-тесты без настоящего ASR E2E"
	@echo "make build       — сборка macOS-приложения"
	@echo "make preview-package — build-only пакет PREVIEW_REF в PREVIEW_OUTPUT, без запуска app"
	@echo "make check-rust  — юнит-тесты Rust-sidecar без модели"

build:
	xcodebuild build -scheme golos-meet -destination 'platform=macOS' -derivedDataPath "$(DERIVED_DATA)" CODE_SIGNING_ALLOWED=NO

test:
	xcodebuild test -scheme golos-meet -destination 'platform=macOS' -derivedDataPath "$(DERIVED_DATA)" -only-testing:golos-meetTests -skip-testing:golos-meetTests/PipelineE2ETests CODE_SIGNING_ALLOWED=NO

check: test

check-rust:
	cd asr && cargo test --lib

preview-package:
	python3 research/preview-package/package_preview.py --ref "$(PREVIEW_REF)" --output "$(PREVIEW_OUTPUT)"
