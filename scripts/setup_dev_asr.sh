#!/usr/bin/env bash
# Dev-only: положить sidecar-бинарь и модель GigaAM туда, где их ищет собранное приложение,
# чтобы переобработка из UI работала. Однократно (повторный запуск — идемпотентен).
set -euo pipefail

REPO="$HOME/Development/golos-meet"
APP_SUPPORT="$HOME/Library/Application Support/golos-meet"
SRC_BIN="$REPO/asr/target/release/golos-asr"
SRC_MODEL="$HOME/Library/Application Support/golos/models/e2e_ctc"
DST_MODEL="$APP_SUPPORT/models/gigaam-v3"

if [ ! -x "$SRC_BIN" ]; then
  echo "Нет release-бинаря sidecar: $SRC_BIN" >&2
  echo "Собери: (cd \"$REPO/asr\" && cargo build --release)" >&2
  exit 1
fi
if [ ! -f "$SRC_MODEL/model.onnx" ] || [ ! -f "$SRC_MODEL/vocab.txt" ]; then
  echo "Нет модели GigaAM: $SRC_MODEL (model.onnx + vocab.txt)" >&2
  exit 1
fi

mkdir -p "$APP_SUPPORT" "$DST_MODEL"
cp "$SRC_BIN" "$APP_SUPPORT/golos-asr"
chmod +x "$APP_SUPPORT/golos-asr"
cp "$SRC_MODEL/model.onnx" "$DST_MODEL/model.onnx"
cp "$SRC_MODEL/vocab.txt" "$DST_MODEL/vocab.txt"

echo "ok: sidecar → $APP_SUPPORT/golos-asr"
echo "ok: модель → $DST_MODEL/{model.onnx,vocab.txt}"
echo "готово"
