.PHONY: help build test check check-rust

DERIVED_DATA ?= $(CURDIR)/.build/xcode

help:
	@echo "make check       — сборка и Swift-тесты без настоящего ASR E2E"
	@echo "make build       — сборка macOS-приложения"
	@echo "make check-rust  — юнит-тесты Rust-sidecar без модели"

build:
	xcodebuild build -scheme golos-meet -destination 'platform=macOS' -derivedDataPath "$(DERIVED_DATA)" CODE_SIGNING_ALLOWED=NO

test:
	xcodebuild test -scheme golos-meet -destination 'platform=macOS' -derivedDataPath "$(DERIVED_DATA)" -only-testing:golos-meetTests -skip-testing:golos-meetTests/PipelineE2ETests CODE_SIGNING_ALLOWED=NO

check: test

check-rust:
	cd asr && cargo test --lib
