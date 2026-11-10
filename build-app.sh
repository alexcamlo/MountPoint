#!/bin/sh
# Builds "Mount Point.app" into ./build. Usage: ./build-app.sh [--install]
# Signs with $SIGN_IDENTITY (default "Win Dev Codesign") so macOS permissions survive rebuilds; ad-hoc if absent (CI).
set -eu
cd "$(dirname "$0")"
swift build -c release
APP="build/Mount Point.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/MountPoint" "$APP/Contents/MacOS/MountPoint"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
IDENTITY="${SIGN_IDENTITY:-Win Dev Codesign}"
security find-identity -p codesigning | grep -qF "\"$IDENTITY\"" || IDENTITY=-
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP (signed: $IDENTITY)"
if [ "${1-}" = "--install" ]; then
  ditto "$APP" "/Applications/Mount Point.app"
  echo "Installed /Applications/Mount Point.app"
fi
