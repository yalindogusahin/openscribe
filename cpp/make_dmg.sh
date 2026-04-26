#!/usr/bin/env bash
# Build a distributable .dmg for OpenScribeNative.
# Run AFTER ./build.sh && ./bundle_helper.sh.
#
# This is an ad-hoc-signed dev build. Apple Developer ID signing and
# notarization (required to bypass Gatekeeper without right-click → Open)
# need a paid Apple Developer account and are deferred.
#
# UX flow: the DMG opens to a 540x380 window with the .app on the left,
# an "Applications" symlink on the right, and a background image showing
# an arrow pointing from one to the other. Drag-to-install, no README.
set -euo pipefail

cd "$(dirname "$0")"

BUNDLE="OpenScribeNative.app"
VERSION="${1:-0.1.0}"
DMG_NAME="OpenScribeNative-$VERSION.dmg"
VOL_NAME="OpenScribe Native"
# Staging lives outside the repo because cpp/ is iCloud-synced and the
# File Provider keeps re-attaching com.apple.FinderInfo to the .app, which
# breaks codesign --verify --strict. /tmp is not synced.
STAGE_DIR="/tmp/openscribe-dmg-staging"
RW_DMG="/tmp/openscribe-rw.dmg"
BG_PNG="/tmp/dmg_background.png"

if [ ! -d "$BUNDLE" ]; then
    echo "error: $BUNDLE not found. Run ./build.sh && ./bundle_helper.sh first."
    exit 1
fi

if [ ! -d "$BUNDLE/Contents/Resources/python" ] || \
   [ ! -d "$BUNDLE/Contents/Resources/stem-helper/site-packages" ]; then
    echo "error: bundle is missing the helper. Run ./bundle_helper.sh first."
    exit 1
fi

# 1. Stage the bundle and re-sign in place (see notes above).
rm -rf "$STAGE_DIR" "$DMG_NAME" "$RW_DMG"
mkdir -p "$STAGE_DIR"
ditto "$BUNDLE" "$STAGE_DIR/$BUNDLE"
xattr -cr "$STAGE_DIR/$BUNDLE"
codesign --force --deep --options=runtime \
         --entitlements entitlements.plist \
         --sign - "$STAGE_DIR/$BUNDLE"
codesign --verify --deep --strict "$STAGE_DIR/$BUNDLE"

# 2. Render the background PNG using the bundled python (PIL is already
#    installed there as a librosa dependency, no host setup required).
echo "Rendering background image..."
PY="$BUNDLE/Contents/Resources/python/bin/python3.11"
SITE="$BUNDLE/Contents/Resources/stem-helper/site-packages"
PYTHONPATH="$SITE" "$PY" dmg_background.py "$BG_PNG"

# 3. Drop the background into a hidden folder Finder respects.
mkdir -p "$STAGE_DIR/.background"
cp "$BG_PNG" "$STAGE_DIR/.background/background.png"

# 4. Applications symlink — this is the drop target on the right.
ln -s /Applications "$STAGE_DIR/Applications"

# 5. Create a writable DMG so we can mutate Finder window state.
echo "Creating writable DMG..."
hdiutil create -srcfolder "$STAGE_DIR" \
               -volname "$VOL_NAME" \
               -fs HFS+ -format UDRW -ov \
               "$RW_DMG" >/dev/null

# 6. Mount and set up the window via AppleScript. We hide the toolbar
#    and sidebar, set a fixed window size, position the two icons, and
#    point the background at our PNG. The .DS_Store written when the
#    window closes is what carries this layout into the read-only DMG.
echo "Configuring window layout..."
hdiutil attach "$RW_DMG" -noautoopen -quiet
sleep 1

osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 100, 740, 480}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set background picture of viewOptions to file ".background:background.png"
        set position of item "$BUNDLE" of container window to {130, 200}
        set position of item "Applications" of container window to {410, 200}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Wait for Finder to flush .DS_Store, then detach.
sync
sleep 1
hdiutil detach "/Volumes/$VOL_NAME" -quiet

# 7. Compress to read-only UDZO for distribution.
echo "Compressing to $DMG_NAME..."
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 \
                -o "$DMG_NAME" >/dev/null
rm -f "$RW_DMG"

echo ""
echo "Done. DMG size:"
du -sh "$DMG_NAME"
echo ""
echo "Distribute: $DMG_NAME"
echo "Note: receivers will need to right-click → Open the first time"
echo "      (no Apple Developer ID signature; Gatekeeper will warn)."
