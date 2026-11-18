# Sidecar Binary: Development and Bundling

## Release Binary

The release binary is built via:
```sh
cd asr/
cargo build --release
```

Location: `asr/target/release/golos-asr` (18.6 MB)

---

## Development Workflow

### Override Binary via Environment Variable

When running the Xcode scheme or app, set the environment variable to use a custom binary:

```
GOLOS_MEET_ASR_BIN=/absolute/path/to/golos-asr
```

**Where to set it:**
- **Xcode Scheme:** Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables
- **Shell:** `export GOLOS_MEET_ASR_BIN=/Users/alfa/Development/golos-meet/asr/target/release/golos-asr && open -a Xcode` (or equivalent)

`AppPaths.sidecarBinary` reads this override first, then falls back to `Bundle.main` resource, then `~/Library/Application Support/golos-meet/golos-asr`.

### Model Directory

The GigaAM model must exist at:
```
~/Library/Application Support/golos-meet/models/gigaam-v3/
```

Required files:
- `model.onnx`
- `vocab.txt`

For development, you can symlink or copy an existing golos model directory if available.

### Backfill Option

To reprocess existing recordings on launch (dev only):
```
GOLOS_MEET_BACKFILL=1
```

Set this alongside `GOLOS_MEET_ASR_BIN` in the Xcode scheme environment.

---

## Preview packaging (#25)

Воспроизводимая упаковка для локальной проверки выполняется отдельно от проекта
Xcode; его build phases и `project.pbxproj` менять не требуется:

```sh
make preview-package PREVIEW_REF=<проверенный-SHA> PREVIEW_OUTPUT=/private/tmp/golos-preview
```

Скрипт [package_preview.py](../research/preview-package/package_preview.py)
извлекает указанный git-коммит в новый каталог, собирает app с отдельным
DerivedData и запускает `cargo build --release --locked --jobs 2` для **того же
снимка** `asr/` с отдельным target-dir. Затем копирует только полученный binary
в `Golos Meet.app/Contents/Resources/golos-asr`. Этот путь уже поддерживается
`AppPaths.sidecarBinary`; внешний binary из установленного приложения не нужен
и не копируется.

Динамические зависимости sidecar проверяются отдельно от Swift ONNX framework.
Текущий закреплённый Rust build связывает ORT/Whisper статически и требует только
системные dylib. Если `otool` обнаружит несистемную зависимость, команда
завершится ошибкой с её именем; сначала потребуется явно добавить упаковку
этого runtime соответствующей версии. Swift ONNX не считается заменой Rust runtime.

Упакованная копия получает ad-hoc подпись и проходит статические проверки
архитектур, dylib-путей и `codesign --verify --deep --strict`. Только binary
из этой копии запускается с `--version`/`--help`: `Args::parse` завершает процесс
до `Session::new`, открытия аудио и загрузки модели. App не запускается,
модели не скачиваются и не включаются. Этот smoke не подтверждает транскрибацию.

В manifest записываются source SHA, Cargo.lock hash, версии Rust/Cargo, команда
сборки и хеш исходного binary; инвентарь хранит хеши подписанных файлов.
Notarization, публикация и установка не выполняются. Debug/ad-hoc пакет
предназначен для согласованной локальной проверки, не является готовым релизом.
После завершения всех функциональных PR нужен новый пакет проверенного preview.

План ручной проверки, ограничения временной библиотеки и моделей — в
[инструкции preview](../research/preview-package/README.md).

---

## Fallback Order

`AppPaths.sidecarBinary` resolves in this order:

1. `GOLOS_MEET_ASR_BIN` env var (dev override)
2. `Bundle.main.url(forResource: "golos-asr")` (production: bundled resource)
3. `~/Library/Application Support/golos-meet/golos-asr` (system fallback)

---

## Model install (M2: manual)

В M2 модель GigaAM устанавливается вручную по пути:
```
~/Library/Application Support/golos-meet/models/gigaam-v3/
```

Автоматическая загрузка при первом запуске через `ModelManager` реализована, но **не подключена** к процессу запуска (отложено; URL-дескрипторы/контрольные суммы подлежат подтверждению). Если модель отсутствует, `LocalASR.start()` вернёт ошибку, и встреча будет помечена статусом `failed`.

---

## Notes

- **Dev:** Use env var + `cargo build --release` to iterate quickly
- **Preview:** `make preview-package` includes the sidecar from the same source SHA without modifying Xcode build phases; release distribution remains separate.
- **Model:** Always ensure the GigaAM model is present; the sidecar will not start without it
