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
cp Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"
# App icon: all the sizes macOS asks for, from the 1024 px master.
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
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
  <key>CFBundleIconFile</key><string>AppIcon</string>
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
# A stable identity keeps the Accessibility permission across rebuilds (ad-hoc signatures lose it).
# scripts/create-signing-identity.sh makes one in its own keychain.
if [[ -n "${SIGN_KEYCHAIN:-}" ]]; then
  security unlock-keychain -p "$(cat "${SIGN_KEYCHAIN_PASSWORD_FILE:?}")" "$SIGN_KEYCHAIN"
fi
codesign --force --sign "$IDENTITY" --identifier dev.droidbridge.mac "$APP"
echo "$APP"
