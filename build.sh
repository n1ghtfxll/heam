#!/bin/sh
# Builds heam.app (with its widget) into ./build.
# Usage: ./build.sh [--open | --install | --dmg]
#   --install  copies it to /Applications and opens it
#   --dmg      also packages build/heam-<version>.dmg with the styled installer window
#              (needs dmgbuild: python3 -m venv .venv-dmg && .venv-dmg/bin/pip install dmgbuild)
set -e
cd "$(dirname "$0")"
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP=build/heam.app
WIDGET="$APP/Contents/PlugIns/HeamWidget.appex"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" "$WIDGET/Contents/MacOS"
# ditto keeps the framework's symlinks intact, which its code signature depends on.
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$BIN/heam" "$APP/Contents/MacOS/heam"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
# Sparkle's license asks for its notice to ship with the app.
cp .build/artifacts/sparkle/Sparkle/LICENSE "$APP/Contents/Resources/Sparkle-LICENSE.txt"
cp "$BIN/HeamWidget" "$WIDGET/Contents/MacOS/HeamWidget"
cp Resources/HeamWidget-Info.plist "$WIDGET/Contents/Info.plist"
# Sign inside-out: Sparkle (with its helper apps and XPC services), the extension (sandboxed),
# then the app around them.
codesign --force --deep --sign - "$APP/Contents/Frameworks/Sparkle.framework"
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
  --dmg)
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
    DMG="build/heam-$VERSION.dmg"
    rm -f "$DMG"
    .venv-dmg/bin/dmgbuild -s scripts/dmg-settings.py -D app="$APP" "heam" "$DMG"
    echo "Packaged $DMG" ;;
esac
exit 0
