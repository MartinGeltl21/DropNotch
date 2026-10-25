#!/usr/bin/env bash
# Baut DropNotch.app nach ./build.
#   scripts/build-app.sh            → Release-Build
#   scripts/build-app.sh --run      → bauen und starten
#   scripts/build-app.sh --install  → bauen und nach /Applications kopieren
# Eigene Signatur (verhindert, dass macOS nach jedem Build neu nach Spotify-Zugriff fragt):
#   SIGN_IDENTITY="Apple Development: Dein Name (XXXX)" scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="DropNotch"
APP="build/$APP_NAME.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "$SIGN_IDENTITY" --identifier de.moritz.dropnotch "$APP"
echo "✓ $APP gebaut"

case "${1:-}" in
  --run)
    pkill -x "$APP_NAME" 2>/dev/null || true
    open "$APP"
    ;;
  --install)
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    open "/Applications/$APP_NAME.app"
    echo "✓ nach /Applications installiert und gestartet"
    ;;
esac
