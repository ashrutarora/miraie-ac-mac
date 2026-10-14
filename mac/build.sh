#!/bin/zsh
# Builds "MirAIe AC.app" (Apple silicon + Intel, menu bar only).
#   mac/build.sh          build and install into ~/Applications (for development)
#   mac/build.sh --dmg    build build/MirAIe-AC-<version>.dmg for people to download
set -euo pipefail
cd "$(dirname "$0")"
VERSION=0.2.1
MIN_MACOS=14.0
APP="build/MirAIe AC.app"
SOURCES=(App.swift ACStore.swift Install.swift MirAIe.swift MQTT.swift Views.swift)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/pkg
for arch in arm64 x86_64; do
    swiftc -parse-as-library -O -swift-version 5 -target $arch-apple-macos$MIN_MACOS \
        -o build/MirAIeAC.$arch $SOURCES
done
lipo -create -output "$APP/Contents/MacOS/MirAIeAC" build/MirAIeAC.arm64 build/MirAIeAC.x86_64
rm build/MirAIeAC.arm64 build/MirAIeAC.x86_64

[[ -f build/pkg/AppIcon.icns ]] || swift packaging/make-icon.swift build/pkg
cp build/pkg/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>MirAIe AC</string>
  <key>CFBundleDisplayName</key><string>MirAIe AC</string>
  <key>CFBundleIdentifier</key><string>com.ashrutarora.miraie-ac</string>
  <key>CFBundleExecutable</key><string>MirAIeAC</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>MIT License. Not affiliated with Panasonic.</string>
</dict></plist>
PLIST
codesign -s - -f "$APP"

if [[ "${1:-}" == "--dmg" ]]; then
    VENV=build/venv
    [[ -x $VENV/bin/dmgbuild ]] || { /usr/bin/python3 -m venv $VENV && $VENV/bin/pip install -q --disable-pip-version-check 'dmgbuild==1.6.5'; }
    swift packaging/make-background.swift build/pkg
    tiffutil -cathidpicheck build/pkg/background.png build/pkg/background@2x.png -out build/pkg/background.tiff 2>/dev/null
    DMG="build/MirAIe-AC-$VERSION.dmg"
    rm -f "$DMG"
    # The Settings shortcut wears System Settings' icon (dmgbuild copies with ditto, which keeps it).
    cp packaging/Open-Privacy-Security.inetloc build/pkg/
    swift packaging/set-icon.swift "/System/Applications/System Settings.app" build/pkg/Open-Privacy-Security.inetloc
    $VENV/bin/dmgbuild -s packaging/dmg-settings.py -D app="$APP" \
        -D link=build/pkg/Open-Privacy-Security.inetloc -D background=build/pkg/background.tiff \
        "MirAIe AC" "$DMG"
    echo "Built $DMG"
else
    mkdir -p ~/Applications
    rm -rf ~/Applications/"MirAIe AC.app"
    cp -R "$APP" ~/Applications/
    echo "Installed ~/Applications/MirAIe AC.app"
fi
