.PHONY: help build test check check-rust preview-package e2e render-tests e2e-dsh uitests

DERIVED_DATA ?= $(CURDIR)/.build/xcode
UITESTS_DERIVED_DATA ?= $(CURDIR)/.build/uitests
E2E_RENDER_OUTPUT ?= $(CURDIR)/.build/e2e-renders
PREVIEW_REF ?= HEAD
PREVIEW_OUTPUT ?= .build/preview
PREVIEW_ISOLATED_QA ?= 0

# Preserve CLI/environment values literally, including Make and shell syntax.
# Simple exported variables prevent a second Make expansion; the recipe is constant.
override PREVIEW_REF := $(value PREVIEW_REF)
override PREVIEW_OUTPUT := $(value PREVIEW_OUTPUT)
override PREVIEW_ISOLATED_QA := $(value PREVIEW_ISOLATED_QA)
export PREVIEW_REF PREVIEW_OUTPUT PREVIEW_ISOLATED_QA

help:
	@echo "make check       — сборка и Swift-тесты без настоящего ASR E2E"
	@echo "make build       — сборка macOS-приложения"
	@echo "make e2e         — все уровни (issue #105): make check + render-тесты (U-01/03/04/05/06)"
	@echo "                   + dsh mock-e2e + XCUITest E-01/03/04/06/09; сводка по уровням"
	@echo "make preview-package — build-only пакет PREVIEW_REF в PREVIEW_OUTPUT, без запуска app"
	@echo "  PREVIEW_ISOLATED_QA=1 — отдельный Golos Meet QA с пустыми data/settings/Keychain"
	@echo "make check-rust  — юнит-тесты Rust-sidecar без модели"

build:
	xcodebuild build -scheme golos-meet -destination 'platform=macOS' -derivedDataPath "$(DERIVED_DATA)" CODE_SIGNING_ALLOWED=NO

test:
	xcodebuild test -scheme golos-meet -destination 'platform=macOS' -derivedDataPath "$(DERIVED_DATA)" -only-testing:golos-meetTests -skip-testing:golos-meetTests/PipelineE2ETests CODE_SIGNING_ALLOWED=NO

check: test

check-rust:
	cd asr && cargo test --lib

# E2E-прогон всех уровней (issue #105). Уровень 1 — make check (Swift-тесты).
# Уровень 2 — env-gated render-тесты (PNG в E2E_RENDER_OUTPUT) и dsh mock-e2e
# (мок OpenAI-совместимого LLM, без ключей и сети наружу). Уровень 3 —
# XCUITest E-сценарии над живым приложением в UI-test shell
# (GOLOS_MEET_UI_E2E=1 поверх GOLOS_MEET_TEST_MODE=1, изолированное хранилище).
e2e: test
	@set -e; \
	echo ""; \
	echo "== Уровень 1 (код, make check): PASSED =="; \
	"$(MAKE)" --no-print-directory render-tests; \
	echo "== Уровень 2 (render-тесты U-01/03/04/05/06): PASSED =="; \
	"$(MAKE)" --no-print-directory e2e-dsh; \
	echo "== Уровень 2/3 (dsh mock-e2e): PASSED =="; \
	"$(MAKE)" --no-print-directory uitests; \
	echo "== Уровень 3 (XCUITest E-01/03/04/06/09): PASSED =="; \
	echo ""; \
	echo "make e2e: сводка — уровень 1: pass; уровень 2: pass; уровень 3: pass"; \
	echo "render-отчёты: $(E2E_RENDER_OUTPUT)"

# Render-тесты уровня 2: рендеры пишутся в E2E_RENDER_OUTPUT, в конце
# проверяется, что PNG действительно созданы.
render-tests:
	@set -e; set -o pipefail; \
	mkdir -p "$(E2E_RENDER_OUTPUT)/agent-chat" "$(E2E_RENDER_OUTPUT)/documents" "$(E2E_RENDER_OUTPUT)/settings"; \
	env TEST_RUNNER_GOLOS_MEET_RENDER_AGENT_CHAT="$(E2E_RENDER_OUTPUT)/agent-chat" \
	  TEST_RUNNER_GOLOS_MEET_RENDER_UI_E2E="$(E2E_RENDER_OUTPUT)/documents" \
	  TEST_RUNNER_GOLOS_MEET_RENDER_TALK_SETTINGS=1 \
	  xcodebuild test -scheme golos-meet -destination 'platform=macOS' -derivedDataPath "$(DERIVED_DATA)" \
	  -only-testing:golos-meetTests/AgentChatTests \
	  -only-testing:golos-meetTests/AgentChatUIFlowTests \
	  -only-testing:golos-meetTests/DocumentsImportErrorRenderTests \
	  -only-testing:golos-meetTests/ThemePersistenceUITests \
	  -only-testing:golos-meetTests/TalkAutomaticRenderTests \
	  -only-testing:golos-meetTests/TalkConnectionRenderTests \
	  -only-testing:golos-meetTests/ProjectMemoryPanelTests \
	  2>&1 | tail -5; \
	files=$$(find "$(E2E_RENDER_OUTPUT)" -name '*.png' | wc -l | tr -d ' '); \
	echo "render PNG: $$files"; \
	[ "$$files" -ge 16 ] || { echo "FAIL: render-тесты не создали ожидаемые PNG"; exit 1; }

# dsh mock-e2e: локальный мок LLM, реальные инструменты golos-qa над QA-архивом.
# Свежий worktree не содержит node_modules — ставятся по package-lock.json.
e2e-dsh:
	@cd research/dsh-spike-94 && if [ ! -d node_modules ]; then \
	  echo "dsh: ставлю node_modules по package-lock.json…"; \
	  npm ci --no-audit --no-fund --silent || { echo "FAIL: npm ci для dsh mock-e2e"; exit 1; }; fi
	@sh research/dsh-spike-94/test/e2e-mock.sh

# XCUITest E-сценарии: раннер UI-тестов на macOS должен быть подписан
# (CODE_SIGNING_ALLOWED=NO убивает раннер до установления AX-соединения).
uitests:
	@set -o pipefail; \
	xcodebuild test -scheme golos-meet -destination 'platform=macOS' -derivedDataPath "$(UITESTS_DERIVED_DATA)" \
	  -only-testing:golos-meetUITests CODE_SIGN_IDENTITY="-" 2>&1 | tail -8

preview-package:
	python3 research/preview-package/package_preview.py

