#!/bin/sh
set -eu
TASK_REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TASK_PREVIEW_ROOT="/tmp/golos-recording-menu-preview"
TASK_PREVIEW_APP="$TASK_PREVIEW_ROOT/Golos Recording Preview.app"
mkdir -p "$TASK_PREVIEW_APP/Contents/MacOS" "$TASK_PREVIEW_ROOT/ModuleCache"
cat > "$TASK_PREVIEW_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.golos.recording-menu-preview</string>
<key>CFBundleName</key><string>Golos Recording Preview</string>
<key>CFBundleExecutable</key><string>GolosRecordingPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path "$TASK_PREVIEW_ROOT/ModuleCache" \
  "$TASK_REPO_ROOT/research/recording-menu-preview/Types.swift" \
  "$TASK_REPO_ROOT/research/recording-menu-preview/Main.swift" \
  "$TASK_REPO_ROOT/golos-meet/UI/MenuBar/MenuBarModel.swift" \
  "$TASK_REPO_ROOT/golos-meet/UI/MenuBar/MenuBarController.swift" \
  "$TASK_REPO_ROOT/golos-meet/Util/ElapsedText.swift" \
  -o "$TASK_PREVIEW_APP/Contents/MacOS/GolosRecordingPreview"
printf '%s\n' "$TASK_PREVIEW_APP/Contents/MacOS/GolosRecordingPreview"
