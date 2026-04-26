#!/usr/bin/env python3
"""Render the DMG window background with an arrow pointing app -> Applications.

The DMG window is sized 540x380. Two icons sit on the same Y row, one on
the left, one on the right. We draw a soft gradient backdrop and a single
arrow + caption so the install gesture is obvious to a first-time user.
"""
import sys
from PIL import Image, ImageDraw, ImageFont

W, H = 540, 380
ICON_Y = 200          # mirrors the AppleScript layout
LEFT_X, RIGHT_X = 130, 410

img = Image.new("RGB", (W, H), (250, 250, 252))
draw = ImageDraw.Draw(img)

# Subtle vertical gradient so the window looks intentional.
for y in range(H):
    t = y / H
    r = int(250 - t * 12)
    g = int(250 - t * 10)
    b = int(252 - t * 6)
    draw.line([(0, y), (W, y)], fill=(r, g, b))

# Title text. Try the system SF font; fall back to default.
def load_font(size):
    for path in [
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/Library/Fonts/Arial.ttf",
    ]:
        try:
            return ImageFont.truetype(path, size)
        except Exception:
            continue
    return ImageFont.load_default()

title_font = load_font(20)
sub_font = load_font(13)

title = "Drag OpenScribe Native to your Applications folder"
bbox = draw.textbbox((0, 0), title, font=title_font)
tw = bbox[2] - bbox[0]
draw.text(((W - tw) // 2, 40), title, fill=(60, 60, 70), font=title_font)

sub = "Then double-click the app in Applications to launch."
bbox = draw.textbbox((0, 0), sub, font=sub_font)
sw = bbox[2] - bbox[0]
draw.text(((W - sw) // 2, 70), sub, fill=(120, 120, 130), font=sub_font)

# Arrow from left icon to right icon, drawn above the icons so it doesn't
# overlap their labels (which Finder draws beneath each icon).
arrow_y = ICON_Y - 70
ax_start = LEFT_X + 50
ax_end = RIGHT_X - 50
shaft_color = (90, 130, 220)
draw.line([(ax_start, arrow_y), (ax_end, arrow_y)], fill=shaft_color, width=4)
# Arrowhead (triangle).
ah = 14
draw.polygon(
    [(ax_end, arrow_y), (ax_end - ah, arrow_y - ah // 2),
     (ax_end - ah, arrow_y + ah // 2)],
    fill=shaft_color,
)

img.save(sys.argv[1] if len(sys.argv) > 1 else "dmg_background.png", "PNG")
print(f"wrote {sys.argv[1] if len(sys.argv) > 1 else 'dmg_background.png'}")
