#!/bin/zsh
# Builds Dictate.app with the Command Line Tools (no Xcode needed) and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Dictate.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 \
  -target arm64-apple-macos26.0 \
  -sdk "$(xcrun --show-sdk-path)" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/Dictate"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
mkdir -p ~/Applications
rm -rf ~/Applications/Dictate.app
cp -R "$APP" ~/Applications/Dictate.app
echo "Built and installed ~/Applications/Dictate.app"
