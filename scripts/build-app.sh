#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIGURATION:-release}"
APP_NAME="LG Monitor Volume.app"
APP_DIR="$ROOT/build/$APP_NAME"
BIN_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"

cd "$ROOT"
swift build -c "$CONFIG" --arch arm64 --product MonitorVolumeApp
swift build -c "$CONFIG" --arch arm64 --product lg-monitor-cli

rm -rf "$APP_DIR"
mkdir -p "$BIN_DIR" "$RES_DIR"
cp ".build/arm64-apple-macosx/$CONFIG/MonitorVolumeApp" "$BIN_DIR/MonitorVolumeApp"
cp ".build/arm64-apple-macosx/$CONFIG/lg-monitor-cli" "$BIN_DIR/lg-monitor-cli"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
codesign --force --deep --sign - "$APP_DIR"
printf 'Built %s\n' "$APP_DIR"
