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

## Production Bundling (Deferred to M5)

**Status:** TODO — manual setup in Xcode GUI (no safe CLI tooling for objectVersion 77 pbxproj).

### When to Bundle

When preparing a distributable build (≈M5), add the sidecar to the app bundle so `Bundle.main.url(forResource:"golos-asr")` resolves without env overrides.

### Steps (Manual in Xcode)

1. Open `golos-meet.xcodeproj` in Xcode
2. Select target `golos-meet`
3. Go to Build Phases
4. Add a new "Run Script" phase **before** "Copy Bundle Resources"
5. Paste this script:
   ```sh
   set -e
   cd "$SRCROOT/asr"
   cargo build --release
   cp target/release/golos-asr "$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/golos-asr"
   ```
6. Save and rebuild

### Why Deferred

The project uses Xcode objectVersion 77. There is no safe, stable CLI tooling (`xcodeproj`, `xcodeprojtools`) that can reliably add build phases without corrupting the project file. Hand-editing `project.pbxproj` is error-prone. The deferred step ensures the bundling is done in Xcode's GUI, where the safety checks are built-in.

---

## Fallback Order

`AppPaths.sidecarBinary` resolves in this order:

1. `GOLOS_MEET_ASR_BIN` env var (dev override)
2. `Bundle.main.url(forResource: "golos-asr")` (production: bundled resource)
3. `~/Library/Application Support/golos-meet/golos-asr` (system fallback)

---

## Notes

- **Dev:** Use env var + `cargo build --release` to iterate quickly
- **Prod:** Bundle via Xcode GUI (step above) for distributable builds
- **Model:** Always ensure the GigaAM model is present; the sidecar will not start without it
