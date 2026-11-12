#!/bin/zsh
# Builds "ChatGPT Bar.app" from main.swift — no Xcode project or paid developer account needed.
set -e
cd "$(dirname "$0")"

APP="build/ChatGPT Bar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# Compile the single Swift file into the app's executable.
swiftc -swift-version 5 -O main.swift -o "$APP/Contents/MacOS/ChatGPTBar" \
  -framework Cocoa -framework WebKit -framework ServiceManagement -framework PDFKit

# App settings: LSUIElement = menu bar only (no Dock icon); usage texts for permission prompts.
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ChatGPT Bar</string>
  <key>CFBundleDisplayName</key><string>ChatGPT Bar</string>
  <key>CFBundleIdentifier</key><string>local.chatgpt-bar</string>
  <key>CFBundleExecutable</key><string>ChatGPTBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>ChatGPT Bar reads the page open in Safari, Chrome or Preview so ChatGPT can use it as context. You can turn this off any time with the eye button.</string>
  <key>NSMicrophoneUsageDescription</key><string>ChatGPT voice mode uses the microphone.</string>
</dict></plist>
PLIST

# "Ad-hoc" signature: free, local-only, lets macOS run the app.
codesign --force --deep -s - "$APP"
echo "Built: $(pwd)/$APP"
