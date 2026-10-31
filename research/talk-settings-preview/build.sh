#!/bin/sh
set -eu
TASK_REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TASK_PREVIEW_ROOT=/tmp/golos-talk-settings-preview
TASK_PREVIEW_APP="$TASK_PREVIEW_ROOT/Golos Talk Settings Preview.app"
mkdir -p "$TASK_PREVIEW_APP/Contents/MacOS" "$TASK_PREVIEW_ROOT/ModuleCache"
cat > "$TASK_PREVIEW_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.golos.talk-settings-preview</string>
<key>CFBundleName</key><string>Golos Talk Settings Preview</string>
<key>CFBundleExecutable</key><string>GolosTalkSettingsPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor -module-cache-path "$TASK_PREVIEW_ROOT/ModuleCache" \
 "$TASK_REPO_ROOT/research/talk-settings-preview/Stubs.swift" \
 "$TASK_REPO_ROOT/research/talk-settings-preview/Main.swift" \
 "$TASK_REPO_ROOT/golos-meet/Core/Talk/TalkAPIClient.swift" \
 "$TASK_REPO_ROOT/golos-meet/Core/Talk/TalkConnection.swift" \
 "$TASK_REPO_ROOT/golos-meet/Core/Talk/TalkMeetingSettings.swift" \
 "$TASK_REPO_ROOT/golos-meet/Core/Talk/TalkRoomConfiguration.swift" \
 "$TASK_REPO_ROOT/golos-meet/Core/Talk/TalkRequestBudget.swift" \
 "$TASK_REPO_ROOT/golos-meet/UI/Settings/TalkConnectionSettings.swift" \
 "$TASK_REPO_ROOT/golos-meet/UI/Settings/TalkMeetingSettingsView.swift" \
 "$TASK_REPO_ROOT/golos-meet/UI/DesignSystem/Palette.swift" \
 "$TASK_REPO_ROOT/golos-meet/UI/DesignSystem/Components.swift" \
 -o "$TASK_PREVIEW_APP/Contents/MacOS/GolosTalkSettingsPreview"
printf '%s\n' "$TASK_PREVIEW_APP/Contents/MacOS/GolosTalkSettingsPreview"
