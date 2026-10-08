#!/usr/bin/env bash
# Native macOS C++ POC build. No CMake — just clang.
set -e

cd "$(dirname "$0")"

BUNDLE="OpenScribeNative.app"
EXE_NAME="OpenScribeNative"
BUNDLE_ID="com.yalindogusahin.openscribe.native"
VERSION="${1:-0.1.0}"

mkdir -p build

echo "Compiling Metal shaders..."
xcrun -sdk macosx metal -c src/WaveformShaders.metal -o build/WaveformShaders.air
xcrun -sdk macosx metallib build/WaveformShaders.air -o build/default.metallib

echo "Compiling..."
clang++ -std=c++20 -fobjc-arc \
    -O2 -Wall -Wextra \
    -mmacosx-version-min=13.0 \
    -framework Cocoa \
    -framework PDFKit \
    -framework UniformTypeIdentifiers \
    -framework AudioToolbox \
    -framework CoreAudio \
    -framework AVFoundation \
    -framework AudioUnit \
    -framework Metal \
    -framework MetalKit \
    -framework QuartzCore \
    -Isrc \
    src/main.mm \
    src/AppDelegate.mm \
    src/MainWindow.mm \
    src/IRealLibrary.mm \
    src/AudioEngine.mm \
    src/WaveformView.mm \
    src/TimelineRulerView.mm \
    src/SettingsWindowController.mm \
    src/StemSeparator.mm \
    src/BasicPitchTranscriber.mm \
    src/ChordRecognizer.mm \
    src/MediaDownloader.mm \
    -o "build/$EXE_NAME"

echo "Bundling..."
# Preserve Resources/{python,stem-helper,media-helper,torch_cache,...}
# across rebuilds so a UI-only iteration doesn't trigger re-running
# bundle_helper.sh (which re-downloads ~760 MB of ML models). Only the
# executable, shaders, icon, and Info.plist need refreshing.
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"
rm -f "$BUNDLE/Contents/MacOS/$EXE_NAME"
cp "build/$EXE_NAME" "$BUNDLE/Contents/MacOS/$EXE_NAME"
mkdir -p "$BUNDLE/Contents/Resources/ireal-helper"
cp ../tools/ireal-helper/library.py ../tools/ireal-helper/THIRD_PARTY_NOTICES.md "$BUNDLE/Contents/Resources/ireal-helper/"
mkdir -p "$BUNDLE/Contents/Resources/transcribe-helper"
cp ../tools/transcribe-helper/transcribe.py "$BUNDLE/Contents/Resources/transcribe-helper/transcribe.py"
cp build/default.metallib "$BUNDLE/Contents/Resources/default.metallib"
if [ -f AppIcon.icns ]; then
    cp AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
fi

cat > "$BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$EXE_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>OpenScribe Native</string>
    <key>CFBundleDisplayName</key>
    <string>OpenScribe Native</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

codesign --force --deep --options=runtime \
         --entitlements entitlements.plist \
         --sign - "$BUNDLE"

echo "Done: $BUNDLE"
echo "Run: open $BUNDLE"
