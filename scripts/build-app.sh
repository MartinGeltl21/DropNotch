#!/usr/bin/env bash
# Builds DropNotch.app into ./build.
#   scripts/build-app.sh            → release build
#   scripts/build-app.sh --run      → build and launch
#   scripts/build-app.sh --install  → build and copy to /Applications
#   scripts/build-app.sh --zip      → additionally create build/DropNotch-<version>.zip
# Flags can be combined (e.g. --zip --install).
# Environment variables:
#   UNIVERSAL=1      → universal binary (arm64 + x86_64)
#   VERSION=1.2.3    → CFBundleShortVersionString (a leading "v" is stripped,
#                      default: value from Resources/Info.plist); CFBundleVersion = number of commits
#   UNIVERSAL=1 VERSION=0.2.0 scripts/build-app.sh --zip
# Your own signing identity (keeps macOS from asking for Spotify access again after every build):
#   SIGN_IDENTITY="Apple Development: Your Name (XXXX)" scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="DropNotch"
APP="build/$APP_NAME.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

DO_RUN=0
DO_INSTALL=0
DO_ZIP=0
for arg in "$@"; do
  case "$arg" in
    --run) DO_RUN=1 ;;
    --install) DO_INSTALL=1 ;;
    --zip) DO_ZIP=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 64 ;;
  esac
done

# Build (optional universal)
BUILD_ARGS=(-c release)
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

# Determine version
VERSION="${VERSION:-$("$PLIST_BUDDY" -c "Print :CFBundleShortVersionString" Resources/Info.plist)}"
VERSION="${VERSION#v}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || "$PLIST_BUDDY" -c "Print :CFBundleVersion" Resources/Info.plist)"

# Assemble bundle
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
"$PLIST_BUDDY" -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
"$PLIST_BUDDY" -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
codesign --force --sign "$SIGN_IDENTITY" --identifier de.moritz.dropnotch "$APP"
echo "✓ Built $APP (version $VERSION, build $BUILD_NUMBER, $(lipo -archs "$APP/Contents/MacOS/$APP_NAME"))"

if [[ "$DO_ZIP" == "1" ]]; then
  ZIP="build/$APP_NAME-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
  echo "✓ Created $ZIP"
fi

if [[ "$DO_INSTALL" == "1" ]]; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  open "/Applications/$APP_NAME.app"
  echo "✓ Installed to /Applications and launched"
elif [[ "$DO_RUN" == "1" ]]; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  open "$APP"
fi
