#!/bin/bash
# Build PriorityManagement.app.
#   ./build.sh                  builds for this Mac and installs to /Applications
#   ./build.sh /path/App.app    builds to a different location
#   ARCH=x86_64 ./build.sh ...  cross-builds for Intel (default: this Mac's architecture)
set -e
cd "$(dirname "$0")"
APP="${1:-/Applications/PriorityManagement.app}"
ARCH="${ARCH:-$(uname -m)}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp bundle/Info.plist "$APP/Contents/Info.plist"
cp -R bundle/Resources/. "$APP/Contents/Resources/"
swiftc -O -swift-version 5 -target "$ARCH-apple-macos14.4" BeatEngine.swift main.swift \
  -o "$APP/Contents/MacOS/PriorityManagement" \
  -framework Cocoa -framework Accelerate -framework CoreAudio
codesign --force --deep --sign - --entitlements prioritymanagement.entitlements "$APP"
echo "built $ARCH: $APP"
