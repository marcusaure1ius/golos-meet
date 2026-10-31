#!/bin/sh
set -eu
TASK_REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TASK_PREVIEW_ROOT=/tmp/golos-talk-runtime-preview
TASK_PREVIEW_APP="$TASK_PREVIEW_ROOT/Golos Talk Runtime Preview.app"
mkdir -p "$TASK_PREVIEW_APP/Contents/MacOS" "$TASK_PREVIEW_ROOT/ModuleCache"
cat > "$TASK_PREVIEW_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.golos.talk-runtime-preview</string>
<key>CFBundleName</key><string>Golos Talk Runtime Preview</string>
<key>CFBundleExecutable</key><string>GolosTalkRuntimePreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor -module-cache-path "$TASK_PREVIEW_ROOT/ModuleCache" \
 "$TASK_REPO_ROOT/research/talk-runtime-preview/Stubs.swift" \
 "$TASK_REPO_ROOT/research/talk-runtime-preview/Main.swift" \
 "$TASK_REPO_ROOT/golos-meet/Core/Talk/TalkAPIClient.swift" \
 "$TASK_REPO_ROOT/golos-meet/Core/Talk/TalkConnection.swift" \
 "$TASK_REPO_ROOT/golos-meet/Core/Talk/TalkMeetingSettings.swift" \
 "$TASK_REPO_ROOT/golos-meet/Core/Talk/TalkRoomConfiguration.swift" \
 "$TASK_REPO_ROOT/golos-meet/Core/Talk/TalkRequestBudget.swift" \
 "$TASK_REPO_ROOT/golos-meet/Core/Talk/TalkRecordingMode.swift" \
 "$TASK_REPO_ROOT/golos-meet/Core/Talk/TalkRoomObserver.swift" \
 "$TASK_REPO_ROOT/golos-meet/Core/RecordingState.swift" \
 "$TASK_REPO_ROOT/golos-meet/UI/MenuBar/MenuBarModel.swift" \
 "$TASK_REPO_ROOT/golos-meet/UI/MenuBar/MenuBarController.swift" \
 "$TASK_REPO_ROOT/golos-meet/Util/ElapsedText.swift" \
 "$TASK_REPO_ROOT/golos-meet/UI/Settings/TalkConnectionSettings.swift" \
 "$TASK_REPO_ROOT/golos-meet/UI/Settings/TalkMeetingSettingsView.swift" \
 "$TASK_REPO_ROOT/golos-meet/UI/DesignSystem/Palette.swift" \
 "$TASK_REPO_ROOT/golos-meet/UI/DesignSystem/Components.swift" \
 -o "$TASK_PREVIEW_APP/Contents/MacOS/GolosTalkRuntimePreview"
printf '%s\n' "$TASK_PREVIEW_APP/Contents/MacOS/GolosTalkRuntimePreview"
