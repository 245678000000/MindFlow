#!/bin/zsh
# Usage: ./build.sh            → native arch, fast
#        ./build.sh universal  → arm64 + x86_64
set -e
cd "$(dirname "$0")"
VERSION=$(cat VERSION)
BUILD_NUM=$(git rev-list --count HEAD 2>/dev/null || echo 1)
APP=build/MindFlow.app

if [[ "$1" == "universal" ]]; then
  swift build -c release --triple arm64-apple-macosx14.0
  swift build -c release --triple x86_64-apple-macosx14.0
  BIN_ARM=.build/arm64-apple-macosx/release/MindFlow
  BIN_X86=.build/x86_64-apple-macosx/release/MindFlow
else
  swift build -c release
fi

rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ "$1" == "universal" ]]; then
  lipo -create "$BIN_ARM" "$BIN_X86" -output "$APP/Contents/MacOS/MindFlow"
else
  cp .build/release/MindFlow "$APP/Contents/MacOS/"
fi
cp Resources/Info.plist "$APP/Contents/"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUM" "$APP/Contents/Info.plist"

if [ ! -f Resources/AppIcon.icns ]; then
  TMP=$(mktemp -d); swift scripts/make_icon.swift "$TMP/icon.png"
  SET="$TMP/AppIcon.iconset"; mkdir "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --deep -s - "$APP"
echo "Built $APP ($VERSION)"
