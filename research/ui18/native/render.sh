#!/bin/sh
set -eu
cd "$(dirname "$0")/../../.."
OUTPUT="${1:-research/ui18/renders}"
BUILD_DIR="$PWD/.build/ui18-native"
mkdir -p "$BUILD_DIR/GolosUI18Research.app/Contents/MacOS" "$BUILD_DIR/module-cache"
cat > "$BUILD_DIR/GolosUI18Research.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.golos.research.ui18.synthetic</string>
<key>CFBundleExecutable</key><string>MockHost</string>
<key>CFBundleName</key><string>Golos UI18 Research</string>
<key>LSMinimumSystemVersion</key><string>14.4</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -target arm64-apple-macos14.4 \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -framework SwiftUI -framework AppKit research/ui18/native/MockHost.swift \
  -o "$BUILD_DIR/GolosUI18Research.app/Contents/MacOS/MockHost"
"$BUILD_DIR/GolosUI18Research.app/Contents/MacOS/MockHost" --export "$OUTPUT"
python3 research/ui18/native/record-renders.py "$OUTPUT"
