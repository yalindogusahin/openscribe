#!/usr/bin/env bash
# Native macOS C++ POC build. No CMake — just clang.
set -e

cd "$(dirname "$0")"

BUNDLE="OpenScribeNative.app"
EXE_NAME="OpenScribeNative"
BUNDLE_ID="com.yalindogusahin.openscribe.native"
VERSION="0.1.0"

mkdir -p build

echo "Compiling Metal shaders..."
xcrun -sdk macosx metal -c src/WaveformShaders.metal -o build/WaveformShaders.air
xcrun -sdk macosx metallib build/WaveformShaders.air -o build/default.metallib

echo "Compiling..."
clang++ -std=c++20 -fobjc-arc \
    -O2 -Wall -Wextra \
    -mmacosx-version-min=13.0 \
    -framework Cocoa \
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
    src/AudioEngine.mm \
    src/WaveformView.mm \
    src/TimelineRulerView.mm \
    -o "build/$EXE_NAME"

echo "Bundling..."
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"
cp "build/$EXE_NAME" "$BUNDLE/Contents/MacOS/$EXE_NAME"
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

codesign --force --sign - "$BUNDLE"

echo "Done: $BUNDLE"
echo "Run: open $BUNDLE"
