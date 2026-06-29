# CLAUDE.md — golos-meet

Нативное macOS-приложение: пишет встречу (Контур.Толк) двумя дорожками, локально расшифровывает, далее (следующий слой) — action points через облачный LLM. Деталь продукта — `docs/brd.md`, архитектура — `docs/arch.md` (оба вне git).

## Состояние
- **M1 (готово):** автономный записывальщик — детект встречи (аудио `kontur.talk*` ИЛИ окно звонка + grace), запись `mic.wav` + `system.wav` (16 кГц mono Int16) + `meta.json`.
- **M2 (готово):** локальная транскрибация — VAD-нарезка + GigaAM/Whisper через Rust-sidecar, склейка «я/участники» по таймкодам → `transcript.json` + `transcript.md`, статусы встречи.
- **UI (готово):** Dock-приложение в дизайн-языке `golos` — сайдбар (Встречи/Настройки), лента встреч ⇄ календарь, детали с транскриптом «я/участники», экран настроек (модель ASR + тема). Read-model `MeetingLibrary` (скан `meetings/`, эффективный статус, lazy-транскрипт). Action points — следующий слой (LLM).
- **Дальше:** UI (лента встреч + детали), затем LLM-постобработка (заголовок/конспект/action points). См. «Отложено до UI».

## Сборка и тесты
- **Swift-приложение:** `xcodebuild build -scheme golos-meet -destination 'platform=macOS'`
- **Swift-тесты:** `xcodebuild test -scheme golos-meet -destination 'platform=macOS' -only-testing:golos-meetTests`
  (используем именно `-only-testing:golos-meetTests` — бандл `golos-meetUITests` пустой/падает, это известный предсуществующий шум.)
- **Rust-sidecar:** из `asr/` — `cargo test --lib` (юниты без модели); `cargo build --release` (бинарь).
- **Реальный e2e (gated):** `GOLOS_MEET_ASR_BIN=$PWD/asr/target/release/golos-asr GOLOS_MEET_GIGAAM_DIR="$HOME/Library/Application Support/golos/models/e2e_ctc" xcodebuild test ... -only-testing:golos-meetTests/PipelineE2ETests` — прогоняет настоящий пайплайн с живым sidecar; без env-переменных тест скипается.

## Архитектура (модульный монолит)
Поток: `MeetingDetector` → `Recorder` → (`meetingEnded`) → `ProcessingPipeline` → `LocalASR`↔sidecar → `TranscriptMerger` → файлы + статус.

Swift (`golos-meet/`):
- `AppCoordinator` — сводит сигналы (аудио `AudioProcessMonitor` ИЛИ окно `WindowMonitor`) в `MeetingDetector.handle(active:at:)` (OR-логика).
- `Core/MeetingDetector` — grace-машина: started/ended. `Core/Recorder` — пишет 2 дорожки + meta, по `meetingEnded` запускает `ProcessingPipeline`.
- `Core/ASR/` — `SidecarProtocol` (JSON-lines), `LocalASR` (actor: spawn sidecar, load, transcribe_file; **неблокирующий** reader через `readabilityHandler`), `ModelManager` (download-on-first-run; **пока не подключён**), `ASRModel` (выбор Скорость/Качество + `ASRSettings`).
- `Core/Transcript/` — `TranscriptModels`, `TranscriptMerger` (мерж двух дорожек по `start`, метки me/participants).
- `Core/Pipeline/` — `ProcessingPipeline` (порог 5 мин, статусы, ASR, merge, запись), `MeetingStatus`, `Backfill` (dev-флаг), `StartupRecovery` (залипшие processing/recording → failed).
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
- **Коммиты:** `[type] описание` — одна строка, без трейлеров (`[feat]/[fix]/[refactor]/[test]/[chore]/[docs]`).
- **Xcode:** проект использует синхронизированные группы (`objectVersion 77`) — новые файлы подхватываются по каталогу, **`project.pbxproj` править не нужно**.
- `docs/` и `.claude/` — вне git (`.gitignore`).
- SourceKit в редакторе часто пишет «Cannot find type …» для межфайловых символов — это шум анализа вне модуля; авторитетен `xcodebuild`/`cargo`.

## Отложено до UI (намеренно, чтобы не переделывать)
- **`MeetingLibrary` read-model:** единая точка чтения/листинга встреч с вычислением «эффективного» статуса (старые M1-встречи: `status=nil` + есть `transcript.json` → ready; есть аудио без транскрипта → нужна обработка; сирота без meta → восстановить). Сейчас сканирование папок дублируется в `StartupRecovery`/`Backfill` — при UI свести в один сервис.
- **Последовательная очередь обработки:** сейчас каждая встреча поднимает свой sidecar; параллельные встречи могут грузить 2× Whisper (~3ГБ) одновременно. Ввести сериализацию при UI.
- **ModelManager** подключить (download-on-first-run, экран загрузки модели); уточнить URL/sha/размеры дескрипторов.
- **Terminate-handler** (дозаписать встречу при выходе) и ремонт WAV-заголовка осиротевших записей.
