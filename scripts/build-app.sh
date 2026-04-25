#!/usr/bin/env bash
# Usage: bash scripts/build-app.sh [version]
# Builds a release .app bundle in the project root.
set -e

VERSION=${1:-"0.0.0"}
BUNDLE="OpenScribe.app"

echo "Building OpenScribe $VERSION (release)..."
swift build -c release

echo "Creating app bundle..."
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"

cp .build/release/OpenScribe "$BUNDLE/Contents/MacOS/OpenScribe"

cat > "$BUNDLE/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>OpenScribe</string>
    <key>CFBundleIdentifier</key>
    <string>com.yalindogusahin.openscribe</string>
    <key>CFBundleName</key>
    <string>OpenScribe</string>
    <key>CFBundleDisplayName</key>
    <string>OpenScribe</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

# Ad-hoc code sign so macOS doesn't block execution
codesign --force --deep --sign - "$BUNDLE"

echo ""
echo "Done: $BUNDLE"
echo "Open with: open $BUNDLE"
