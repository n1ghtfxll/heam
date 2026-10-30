#!/bin/sh
# Builds heam.app (with its widget) into ./build.
# Usage: ./build.sh [--open | --install]   --install copies it to /Applications and opens it.
set -e
cd "$(dirname "$0")"
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP=build/heam.app
WIDGET="$APP/Contents/PlugIns/HeamWidget.appex"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$WIDGET/Contents/MacOS"
cp "$BIN/heam" "$APP/Contents/MacOS/heam"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/HeamWidget" "$WIDGET/Contents/MacOS/HeamWidget"
cp Resources/HeamWidget-Info.plist "$WIDGET/Contents/Info.plist"
# Sign inside-out: the extension first (sandboxed), then the app around it.
codesign --force --sign - --entitlements Resources/HeamWidget.entitlements "$WIDGET"
codesign --force --sign - "$APP"
echo "Built $APP"
case "$1" in
  --open) open "$APP" ;;
  --install)
    pkill -x heam 2>/dev/null && sleep 1 || true
    rm -rf /Applications/heam.app
    cp -R "$APP" /Applications/heam.app
    open /Applications/heam.app
    echo "Installed /Applications/heam.app" ;;
esac
exit 0
