# golos-asr

Sidecar binary для приложения [golos](https://github.com/...). Транскрибирует аудио через GigaAM-v3 ONNX, общается с родительским процессом по JSON-lines протоколу.

## Сборка

```bash
# Локально под текущую архитектуру:
cargo build --release

# Apple Silicon-only release с подписью (если задан APPLE_DEVELOPER_ID):
./scripts/build-universal.sh
```

> Intel Mac (x86_64) сейчас не поддерживается — `ort-sys` (через `transcribe-rs`) не поставляет prebuilt ONNX Runtime под x86_64. См. `plan.md` в корне проекта.

## Запуск

```bash
golos-asr [--audio-path <fifo>]
```

`--audio-path` — путь к FIFO/файлу, через который Swift app шлёт сырые сэмплы (Int16 LE, 16kHz mono). Опционален: в batch-режиме (`TranscribeFile`) audio-путь не нужен.

## Протокол

**stdin (Request):** одна JSON-строка на сообщение, разделитель `\n`.

| `type`            | поля                       | описание                                           |
|-------------------|----------------------------|----------------------------------------------------|
| `load`            | `model_path` (string)      | загрузить ONNX-bundle GigaAM-v3                    |
| `transcribe_file` | `path` (string)            | batch-режим: транскрибировать WAV-файл целиком     |
| `begin_session`   | —                          | начать новую запись (audio идёт через --audio-path)|
| `end_session`     | `samples_total` (u64)      | финализировать, ждать `final`                      |
| `cancel`          | —                          | отменить запись без транскрипции                   |
| `shutdown`        | —                          | graceful shutdown                                  |

### Batch-режим (transcribe_file)

Типичный поток запросов для обработки готового WAV-файла:

```
→ {"type":"load","id":1,"model_path":"/path/to/gigaam-v3"}
← {"type":"ready","id":1}
→ {"type":"transcribe_file","id":2,"path":"/path/to/audio.wav"}
← {"type":"segments","id":2,"segments":[{"start":0.0,"end":2.5,"text":"..."}],"duration_ms":430}
→ {"type":"shutdown","id":3}
```

**stdout (Response):**

| `type`            | поля                                  | описание                                    |
|-------------------|---------------------------------------|---------------------------------------------|
| `hello`           | `version`                             | сразу после старта                          |
| `ready`           | —                                     | модель загружена                            |
| `session_started` | —                                     | сессия начата                               |
| `segments`        | `segments`, `duration_ms`             | результат transcribe_file                   |
| `final`           | `text`, `duration_ms`                 | финальный transcript (streaming-режим)      |
| `cancelled`       | —                                     | подтверждение cancel                        |
| `error`           | `kind`, `message`                     | любая ошибка                                |

**stderr:** logs (управляется `GOLOS_ASR_LOG`, формат `tracing-subscriber` env_filter — например, `GOLOS_ASR_LOG=debug`).

## Тесты

```bash
cargo test --lib                                           # unit-тесты (без модели)
GOLOS_ASR_MODEL_DIR=/path/to/giga-am-v3 cargo test         # все, включая e2e (требует ONNX-bundle)
```

## Зависимости

См. `Cargo.toml`. Ключевое: `transcribe-rs 0.3` с feature `onnx`. Модели — отдельно (см. `BUNDLING.md`).
