#!/bin/zsh
# Builds "GPT Menubar.app" from main.swift — no Xcode project or paid developer account needed.
set -e
cd "$(dirname "$0")"

APP="build/GPT Menubar.app"
rm -rf "$APP"
rm -rf "build/ChatGPT Bar.app"     # old name of this app, from before the rename
mkdir -p "$APP/Contents/MacOS"

# Compile the single Swift file into the app's executable.
swiftc -swift-version 5 -O main.swift -o "$APP/Contents/MacOS/GPTMenubar" \
  -framework Cocoa -framework WebKit -framework ServiceManagement -framework PDFKit

# App settings: LSUIElement = menu bar only (no Dock icon); usage texts for permission prompts.
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>GPT Menubar</string>
  <key>CFBundleDisplayName</key><string>GPT Menubar</string>
  <key>CFBundleIdentifier</key><string>local.gpt-menubar</string>
  <key>CFBundleExecutable</key><string>GPTMenubar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>GPT Menubar reads the page open in Safari, Chrome or Edge, the PDF open in Preview, or the song playing in Spotify, so ChatGPT can use it as context. You can turn this off any time from the menu bar icon's right-click menu.</string>
  <key>NSMicrophoneUsageDescription</key><string>ChatGPT voice mode uses the microphone.</string>
  <key>NSServices</key>
  <array><dict>
    <key>NSMenuItem</key><dict><key>default</key><string>Ask ChatGPT</string></dict>
    <key>NSMessage</key><string>askChatGPT</string>
    <key>NSPortName</key><string>GPT Menubar</string>
    <key>NSSendTypes</key><array><string>public.utf8-plain-text</string><string>NSStringPboardType</string></array>
    <!-- Only offered in these apps (Spotify has no text to select) -->
    <key>NSRequiredContext</key><dict><key>NSApplicationIdentifier</key>
      <array><string>com.apple.Safari</string><string>com.google.Chrome</string><string>com.microsoft.edgemac</string><string>com.apple.Preview</string></array>
    </dict>
  </dict></array>
</dict></plist>
PLIST

# "Ad-hoc" signature: free, local-only, lets macOS run the app.
codesign --force --deep -s - "$APP"

# Tell macOS about the right-click "Ask ChatGPT" service.
/System/Library/CoreServices/pbs -update 2>/dev/null || true
echo "Built: $(pwd)/$APP"
