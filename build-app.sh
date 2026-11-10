#!/bin/sh
# Builds "Mount Point.app" into ./build. Usage: ./build-app.sh [--install]
# Signs with $SIGN_IDENTITY (default: any "Apple Development" cert, whose Team ID keeps macOS permissions
# such as Local Network across rebuilds); ad-hoc if none is installed (CI).
set -eu
cd "$(dirname "$0")"
# SwiftPM stamps the deployment target as the SDK version, which runs the app in macOS 15
# compatibility mode (no Liquid Glass sidebar/toolbar). Stamp the real SDK instead.
swift build -c release -Xlinker -platform_version -Xlinker macos -Xlinker 15.0 -Xlinker "$(xcrun --show-sdk-version)"
APP="build/Mount Point.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/MountPoint" "$APP/Contents/MacOS/MountPoint"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
IDENTITY="${SIGN_IDENTITY:-Apple Development}"
security find-identity -v -p codesigning | grep -qF "\"$IDENTITY" || IDENTITY=-
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP (signed: $IDENTITY)"
if [ "${1-}" = "--install" ]; then
  ditto "$APP" "/Applications/Mount Point.app"
  echo "Installed /Applications/Mount Point.app"
fi
