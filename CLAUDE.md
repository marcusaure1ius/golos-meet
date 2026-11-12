# CLAUDE.md — golos-meet

Процесс разработки (issues, чаты этапов, worktree, проверки и независимое ревью) — в `AGENTS.md`. Agent Board не используется.

Нативное macOS-приложение: пишет встречу (Контур.Толк) двумя дорожками, локально расшифровывает, далее (следующий слой) — action points через облачный LLM. Деталь продукта — `docs/brd.md`, архитектура — `docs/arch.md` (оба вне git).

## Состояние
- **M1 (готово):** автономный записывальщик — детект встречи (захват микрофона `kontur.talk*` ИЛИ окно звонка + grace; один вывод звука Толка не считается — на macOS 27 его поток висит и вне звонка), запись `mic.wav` + `system.wav` (16 кГц mono Int16) + `meta.json`.
- **M2 (готово):** локальная транскрибация — VAD-нарезка + GigaAM/Whisper через Rust-sidecar, склейка «я/участники» по таймкодам → `transcript.json` + `transcript.md`, статусы встречи.
- **UI (готово):** Dock-приложение в дизайн-языке `golos` — сайдбар (Встречи/Настройки), лента встреч ⇄ календарь, детали с транскриптом «я/участники», экран настроек (модель ASR + тема). Поиск по встречам/расшифровкам + фильтр по периоду, действия над встречей (переименовать/удалить/копировать конспект), аудиоплеер с перемоткой по транскрипту, чекбоксы на action points.
- **Надёжность (готово):** единая FIFO-очередь обработки (`MeetingProcessor`: `.process`/`.insights`, дедупликация, баннер «Обрабатываю N встреч»), terminate-handler (финализация записи при выходе), `WavRepair` + `StartupRescue` (спасённые встречи авто-встают в очередь; `processing` после краша переобрабатывается).
- **LLM-инсайты (готово):** заголовок/конспект/action points через OpenRouter (`Core/Insights/`), `insights.json` + `meta.title`, настройки ключа/модели в UI.
- **Дальше:** дистрибуция (подключить `ModelManager`, бандлинг sidecar — под-проект B) и menu-bar + ручной старт/стоп записи + живая встреча в ленте (под-проект C-4).

## Сборка и тесты
- **Безопасный test host:** схема TestAction задаёт `GOLOS_MEET_TEST_MODE=1`; дополнительно распознаются маркеры XCTest. Рабочий UI, восстановление записей, детектор и автообработка не запускаются. `AppPaths` использует отдельный временный каталог процесса, Keychain — отдельный тестовый service. Изоляция действует и при запуске отдельных тестов через Xcode.
- **Swift-приложение:** `xcodebuild build -scheme golos-meet -destination 'platform=macOS'`
- **Swift-тесты:** `xcodebuild test -scheme golos-meet -destination 'platform=macOS' -only-testing:golos-meetTests`
  (используем именно `-only-testing:golos-meetTests` — бандл `golos-meetUITests` пустой/падает, это известный предсуществующий шум.)
- **Rust-sidecar:** из `asr/` — `cargo test --lib` (юниты без модели); `cargo build --release` (бинарь).
- **Реальный e2e (gated):** `GOLOS_MEET_ASR_BIN=$PWD/asr/target/release/golos-asr GOLOS_MEET_GIGAAM_DIR="$HOME/Library/Application Support/golos/models/e2e_ctc" GOLOS_MEET_E2E_SRC=/path/to/explicitly-selected-audio xcodebuild test ... -only-testing:golos-meetTests/PipelineE2ETests` — прогоняет настоящий пайплайн с живым sidecar; без всех трёх env-переменных тест скипается; схема не содержит путей к моделям и пользовательским записям.

## Архитектура (модульный монолит)
Поток: `MeetingDetector` → `Recorder` → (`meetingEnded`) → очередь `MeetingProcessor` → `ProcessingPipeline` → `LocalASR`↔sidecar → `TranscriptMerger` → файлы + статус.

Swift (`golos-meet/`):
- `TalkNativeRoomSource` → `TalkAutomaticObserver` — новый явно выбранный read-only режим (#72): URL только AXWebArea окон `kontur.talk`, динамические комнаты того же origin, PAT-проверка подтверждённого userKey. Нет ручного списка, mic/title gate и вызовов Recorder; status в настройках/меню, безопасные события present/absent/unknown в Log.detector. `talk-automatic-discovery.json` имеет приоритет над старым режимом; false не включает legacy. Ошибки AX/доступа/сети — unknown. Детали и пределы: `research/TALK_AUTOMATIC_DISCOVERY.md`.
- `AppCoordinator` — выбирает явно сохранённый режим. API: `TalkRoomObserver.observation` (с проверкой свежести) → Recorder; present без mic/window gate, absent завершает, unknown сохраняет текущую запись. Legacy: аудио `AudioProcessMonitor` ИЛИ `WindowMonitor` → `MeetingDetector` с grace. В API fallback отсутствует. `TalkRuntimeSettings` проверяет origin/version/key/комнаты; режим хранится отдельно от PAT. Sleep/config/quit инвалидируют polling, прерванные сегменты защищены.
- `Core/MeetingDetector` — grace-машина: started/ended. `Core/Recorder` — пишет 2 дорожки + meta, по `meetingEnded` финализирует запись (`finalizeActive`, идемпотентно) и ставит задачу в очередь `MeetingProcessor`.
- `Core/ASR/` — `SidecarProtocol` (JSON-lines), `LocalASR` (actor: spawn sidecar, load, transcribe_file; **неблокирующий** reader через `readabilityHandler`), `ModelManager` (download-on-first-run; **пока не подключён**), `ASRModel` (выбор Скорость/Качество + `ASRSettings`).
- `Core/Transcript/` — `TranscriptModels`, `TranscriptMerger` (мерж двух дорожек по `start`, метки me/participants).
- `Core/Pipeline/` — `MeetingProcessor` (единая FIFO-очередь с дедупликацией), `ProcessingPipeline` (порог 5 мин, статусы, ASR, merge, запись), `MeetingStatus`, `Backfill` (dev-флаг), `StartupRescue` (ремонт WAV + авто-очередь).
- `Core/Library/` — `MeetingLibrary` (чтение/листинг встреч), `MeetingStore` (мутации: delete/rename/setActionPointDone), `MeetingSearchIndex` (ленивый поисковый текст), `MeetingFilter` (фильтр по периоду + поиск).
- `Core/Player/` — `MeetingPlayer` (синхронное воспроизведение двух дорожек, seek по таймкодам).
- `Core/Insights/` — `InsightsGenerator` (запрос к OpenRouter), `InsightsMarkdown` (рендер заголовка/конспекта/action points).
- `Util/` — `AppPaths`, `Logger` (`Log.recorder/pipeline/asr/detector/sidecar/...`).

Rust (`asr/`, вендор из соседнего проекта `golos`): `protocol.rs` (Request/Response, `ModelKind` gigaam|whisper), `session.rs`, `transcriber.rs` (движок-агностичный `Box<dyn SpeechModel>`), `segment.rs` (`EnergyVad`-нарезка), `audio.rs`, `main.rs`. Зависит от `transcribe-rs 0.3` (features `onnx,whisper-cpp,whisper-metal`). **`Cargo.lock` закоммичен** (воспроизводимость).

## Данные на диске
`~/Library/Application Support/golos-meet/`
- `meetings/<ГГГГ-ММ-ДД_ЧЧ-ММ-СС>/` — `mic.wav`, `system.wav`, `meta.json`, (после обработки) `transcript.json`, `transcript.md`.
- `models/<id>/` — модели ASR.

`meta.json` (источник правды для будущего UI): `id, source, startedAt, endedAt` (**ISO-8601**), `durationSeconds`, `status` (recording|processing|ready|failed|discarded), `asrModel`, `title`, `schemaVersion` (=1). Пишется атомарно; создаётся при старте встречи (status=recording) и обновляется пайплайном. Старые M1-файлы без новых полей декодируются (опциональны).

`transcript.json`: `{ meetingId, asrModel, segments:[{start,end,speaker,text}] }`; `speaker` = `"me"`/`"participants"` (локализация «я/участники» — только в `.md`/UI). Таймкоды — секунды от начала записи (обе дорожки стартуют в t=0).

## Модели ASR
- **Скорость:** GigaAM-v3 CTC (`models/gigaam-v3/` = `model.onnx`+`vocab.txt`). Для русского сильный и быстрый (~27× быстрее Whisper на CPU). Движок умеет **только CTC** (RNNT не поддерживается).
- **Качество:** Whisper large-v3 (`models/whisper-large-v3/ggml-large-v3.bin`, ~3 ГБ, Metal). ⚠️ галлюцинирует на тихих/пустых дорожках микрофона — для тихого mic безопаснее GigaAM.
- Выбор — `ASRSettings.current` (UserDefaults), по умолчанию `.speed`.
- Dev: модель GigaAM можно взять из соседнего `golos` (`~/Library/Application Support/golos/models/e2e_ctc`); бинарь sidecar — через `GOLOS_MEET_ASR_BIN`. Прод-бандлинг бинаря в .app и download-on-first-run — отложены (см. `asr/BUNDLING.md`).

## Конвенции
- **Коммиты:** `[type] #<issue> описание` — одна строка, без трейлеров (`[feat]/[fix]/[refactor]/[test]/[chore]/[docs]`). Подробности процесса — в `AGENTS.md`.
- **Имена (не путать!):** пользователю — **«Golos Meet»** (`PRODUCT_NAME`/`INFOPLIST_KEY_CFBundleDisplayName` → бандл `Golos Meet.app`). Внутренние имена НЕ менять: target `golos-meet`, bundle id `com.golos.golos-meet`, Swift-модуль `golos_meet` (прибит `PRODUCT_MODULE_NAME = golos_meet` — иначе рвётся `@testable import golos_meet` во всех тестах и меняется designated requirement TCC).
- **Xcode:** проект использует синхронизированные группы (`objectVersion 77`) — новые файлы подхватываются по каталогу, **`project.pbxproj` править не нужно**.
- `docs/` и `.claude/` — вне git (`.gitignore`).
- SourceKit в редакторе часто пишет «Cannot find type …» для межфайловых символов — это шум анализа вне модуля; авторитетен `xcodebuild`/`cargo`.

## Отложено до UI (намеренно, чтобы не переделывать)
- **`MeetingLibrary` read-model (введён в UI-слое):** `Core/Library/` — единая точка чтения/листинга встреч с «эффективным» статусом (есть `transcript.json` → ready; есть аудио без транскрипта → не расшифрована; сирота без meta → id из имени папки).
- **ModelManager** подключить (download-on-first-run, экран загрузки модели); уточнить URL/sha/размеры дескрипторов.
