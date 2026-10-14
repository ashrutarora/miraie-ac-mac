#!/bin/zsh
# Builds "MirAIe AC.app" (menu-bar only) and installs it in ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/MirAIe AC.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -parse-as-library -O -swift-version 5 -target arm64-apple-macos14 \
    -o "$APP/Contents/MacOS/MirAIeAC" App.swift ACStore.swift MirAIe.swift MQTT.swift Views.swift
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>MirAIe AC</string>
  <key>CFBundleIdentifier</key><string>com.ashrutarora.miraie-ac</string>
  <key>CFBundleExecutable</key><string>MirAIeAC</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign -s - -f "$APP"
mkdir -p ~/Applications
rm -rf ~/Applications/"MirAIe AC.app"
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/MirAIe AC.app"
