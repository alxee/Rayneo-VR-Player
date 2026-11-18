#!/bin/sh
# build.sh — compile the player and wrap it in a double-clickable .app bundle.
set -e
cd "$(dirname "$0")"

swift build -c release

APP="build/Rayneo VR Player.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/RayNeoCinema "$APP/Contents/MacOS/Rayneo VR Player"

# App icon: white glasses on black (Resources/AppIcon.png → icns).
ICON_PLIST_KEY=""
if [ -f Resources/AppIcon.png ]; then
    iconset=build/AppIcon.iconset
    rm -rf "$iconset" && mkdir -p "$iconset"
    for s in 16 32 64 128 256 512; do
        sips -z $s $s Resources/AppIcon.png --out "$iconset/icon_${s}x${s}.png" >/dev/null
        d=$((s * 2))
        sips -z $d $d Resources/AppIcon.png --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
    done
    if iconutil -c icns "$iconset" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
        ICON_PLIST_KEY='    <key>CFBundleIconFile</key><string>AppIcon</string>'
    fi
    rm -rf "$iconset"
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Rayneo VR Player</string>
    <key>CFBundleDisplayName</key><string>Rayneo VR Player</string>
    <key>CFBundleIdentifier</key><string>com.alex.rayneovrplayer</string>
    <key>CFBundleVersion</key><string>0.3.0</string>
    <key>CFBundleShortVersionString</key><string>0.3.0</string>
    <key>CFBundleExecutable</key><string>Rayneo VR Player</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
${ICON_PLIST_KEY}
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Built $APP — open it, or: open \"$APP\" path/to/video"
