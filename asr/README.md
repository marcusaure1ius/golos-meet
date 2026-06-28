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
golos-asr --audio-fd <N>
```

`--audio-fd` — POSIX file descriptor открытого pipe, через который Swift app шлёт сырые сэмплы (Int16 LE, 16kHz mono).

## Протокол

**stdin (Request):** одна JSON-строка на сообщение, разделитель `\n`.

| `type`           | поля                       | описание                                   |
|------------------|----------------------------|--------------------------------------------|
| `load`           | `model_path` (string)      | загрузить ONNX-bundle GigaAM-v3            |
| `begin_session`  | —                          | начать новую запись (audio идёт через fd)  |
| `end_session`    | —                          | финализировать, ждать `final`              |
| `cancel`         | —                          | отменить запись без транскрипции           |
| `shutdown`       | —                          | graceful shutdown                          |

**stdout (Response):**

| `type`            | поля                                  | описание                                    |
|-------------------|---------------------------------------|---------------------------------------------|
| `hello`           | `version`                             | сразу после старта                          |
| `ready`           | —                                     | модель загружена                            |
| `session_started` | —                                     | сессия начата                               |
| `final`           | `text`, `duration_ms`                 | финальный transcript                        |
| `cancelled`       | —                                     | подтверждение cancel                        |
| `error`           | `kind`, `message`                     | любая ошибка                                |

**stderr:** logs (управляется `GOLOS_ASR_LOG`, формат `tracing-subscriber` env_filter — например, `GOLOS_ASR_LOG=debug`).

## Тесты

```bash
cargo test --lib                                           # unit-тесты (без модели)
GOLOS_ASR_MODEL_DIR=/path/to/giga-am-v3 cargo test         # все, включая e2e (требует ONNX-bundle)
```

## Зависимости

См. `Cargo.toml`. Ключевое: `transcribe-rs 0.3` с feature `onnx`. Модели — отдельно (download-on-first-run в Swift app).
