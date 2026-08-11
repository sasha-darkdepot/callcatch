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
# Подпись сертификатом Apple Development (стабильная identity: TCC-разрешения
# — Accessibility и т.п. — сохраняются между пересборками, т.к. designated
# requirement привязан к team ID + bundle id, а не к хэшу бинарника).
# Переопределяется через CODESIGN_IDENTITY; ad-hoc ("-") как запасной вариант.
IDENTITY="${CODESIGN_IDENTITY:-Apple Development: Aleksandar Radoslavov (NJZL3R3488)}"
if security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
    codesign -s "$IDENTITY" --force --options runtime "$APP"
    echo "Built $APP (signed: $IDENTITY)"
else
    codesign -s - --force "$APP"
    echo "Built $APP (ad-hoc — '$IDENTITY' not found in keychain)"
fi

# INSTALL=1 — переустановить в /Applications (постоянное место; стабильная
# подпись сохраняет TCC-разрешения, поэтому перевыдавать Accessibility не нужно).
if [ "${INSTALL:-}" = "1" ]; then
    pkill -x CallCatch 2>/dev/null || true
    rm -rf /Applications/CallCatch.app
    cp -R "$APP" /Applications/CallCatch.app
    echo "Installed to /Applications/CallCatch.app"
fi
