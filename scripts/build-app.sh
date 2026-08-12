#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/CallCatch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/CallCatch "$APP/Contents/MacOS/CallCatch"

# Версия выводится из git — единственный источник правды:
#   marketing version = последний тег vX.Y.Z (без 'v'), fallback 0.0.0
#   build number      = число коммитов в HEAD (монотонно растёт)
# Тег vX.Y.Z → релиз X.Y.Z; можно переопределить через MARKETING_VERSION.
MARKETING_VERSION="${MARKETING_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
MARKETING_VERSION="${MARKETING_VERSION:-0.0.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>CallCatch</string>
    <key>CFBundleIdentifier</key><string>dev.sasha.callcatch</string>
    <key>CFBundleName</key><string>Call Catch</string>
    <key>CFBundleDisplayName</key><string>Call Catch</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.4</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
echo "Version: ${MARKETING_VERSION} (build ${BUILD_NUMBER})"
# Подпись сертификатом Apple Development (стабильная identity: TCC-разрешения
# — Accessibility и т.п. — сохраняются между пересборками, т.к. designated
# requirement привязан к team ID + bundle id, а не к хэшу бинарника).
# По умолчанию — первый Apple Development в связке ключей (переносимо между
# машинами с тем же Apple ID); override через CODESIGN_IDENTITY; ad-hoc fallback.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)}"
if [ -n "$IDENTITY" ] && security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
    codesign -s "$IDENTITY" --force --options runtime "$APP"
    echo "Built $APP (signed: $IDENTITY)"
else
    codesign -s - --force "$APP"
    echo "Built $APP (ad-hoc — no Apple Development identity in keychain)"
fi

# INSTALL=1 — переустановить в /Applications (постоянное место; стабильная
# подпись сохраняет TCC-разрешения, поэтому перевыдавать Accessibility не нужно).
if [ "${INSTALL:-}" = "1" ]; then
    pkill -x CallCatch 2>/dev/null || true
    rm -rf "/Applications/CallCatch.app" "/Applications/Call Catch.app"
    cp -R "$APP" "/Applications/Call Catch.app"
    echo "Installed to /Applications/Call Catch.app"
fi
