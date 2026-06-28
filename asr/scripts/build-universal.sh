#!/usr/bin/env bash
# Собирает golos-asr под aarch64-apple-darwin (Apple Silicon).
# Подписывает Developer ID, если задан APPLE_DEVELOPER_ID.
#
# x86_64-apple-darwin не поддерживается — у `ort-sys` (через `transcribe-rs`)
# нет prebuilt-бинарей под Intel Mac. Если когда-нибудь понадобится — можно
# вернуть через ручную сборку ONNX Runtime + ort feature `load-dynamic`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRATE_DIR="$SCRIPT_DIR/.."
cd "$CRATE_DIR"

echo "==> Building golos-asr for aarch64-apple-darwin"
cargo build --release --target aarch64-apple-darwin

OUT_DIR="$CRATE_DIR/target/universal-apple-darwin/release"
mkdir -p "$OUT_DIR"

echo "==> Copying release binary into $OUT_DIR/golos-asr"
cp -f "$CRATE_DIR/target/aarch64-apple-darwin/release/golos-asr" "$OUT_DIR/golos-asr"

if [[ -n "${APPLE_DEVELOPER_ID:-}" ]]; then
    echo "==> Code-signing with: $APPLE_DEVELOPER_ID"
    codesign --force --options runtime --timestamp \
        --sign "$APPLE_DEVELOPER_ID" \
        "$OUT_DIR/golos-asr"
    codesign --verify --strict --verbose=2 "$OUT_DIR/golos-asr"
fi

echo "==> Done."
file "$OUT_DIR/golos-asr"
