#!/usr/bin/env bash
# Builds dist/DroidBridge.app: the Swift menu-bar app plus the Android server jar.
# Env: DROIDBRIDGE_VERSION (default 0.1.0), SIGN_IDENTITY (default "-", ad-hoc), SERVER_JAR (prebuilt jar).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${DROIDBRIDGE_VERSION:-0.1.0}
IDENTITY=${SIGN_IDENTITY:--}
APP=dist/DroidBridge.app

swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/DroidBridge

JAR=${SERVER_JAR:-../server/build/droidbridge-server.jar}
if [[ ! -f "$JAR" ]]; then
  DROIDBRIDGE_VERSION=$VERSION ../server/build.sh
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DroidBridge"
cp "$JAR" "$APP/Contents/Resources/droidbridge-server.jar"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.droidbridge.mac</string>
  <key>CFBundleName</key><string>DroidBridge</string>
  <key>CFBundleDisplayName</key><string>DroidBridge</string>
  <key>CFBundleExecutable</key><string>DroidBridge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>pt-BR</string></array>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Apache License 2.0</string>
</dict>
</plist>
PLIST
codesign --force --sign "$IDENTITY" --identifier dev.droidbridge.mac "$APP"
echo "$APP"
