#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/CallCatch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/CallCatch "$APP/Contents/MacOS/CallCatch"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>CallCatch</string>
    <key>CFBundleIdentifier</key><string>dev.sasha.callcatch</string>
    <key>CFBundleName</key><string>CallCatch</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.4</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign -s - --force "$APP"
echo "Built $APP"
