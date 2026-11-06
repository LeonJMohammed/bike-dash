"""Draws the Bike Dash app icon (run on the PC, needs Pillow).

Leon's icon style: a coloured glyph on a full-bleed white plate, plus a dark
variant with the same glyph on black (iOS 18+ picks it in dark mode).

    python scripts/pc/draw_icon.py BikeDash/Resources/Assets.xcassets/AppIcon.appiconset [preview.png]
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 1024
SS = 4                  # draw 4x larger, then shrink, for smooth edges
CYAN = (6, 182, 212)    # #06b6d4, also the app's accent colour
STROKE = 46
LIFT = -30              # moves the whole glyph up so it sits centred


def draw_bike(img):
    d = ImageDraw.Draw(img)
    w = STROKE * SS

    def pt(x, y):
        return (x * SS, (y + LIFT) * SS)

    def dot(x, y, r):
        cx, cy = pt(x, y)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=CYAN)

    def line(a, b):
        d.line([pt(*a), pt(*b)], fill=CYAN, width=w)
        dot(*a, w / 2)  # round caps
        dot(*b, w / 2)

    def wheel(x, y, r):
        cx, cy = pt(x, y)
        R = r * SS
        d.ellipse([cx - R, cy - R, cx + R, cy + R], outline=CYAN, width=w)

    rear, front = (300, 620), (724, 620)
    crank, seat = (476, 620), (424, 420)
    head_top, head_bottom = (676, 412), (694, 470)

    wheel(*rear, 168)
    wheel(*front, 168)
    line(rear, crank)              # chainstay
    line(rear, seat)               # seatstay
    line(seat, crank)              # seat tube
    line(seat, head_top)           # top tube
    line(crank, head_bottom)       # down tube
    line(head_top, head_bottom)    # head tube
    line(head_bottom, front)       # fork
    line(seat, (408, 356))         # seat post
    line((356, 350), (466, 350))   # saddle
    line(head_top, (664, 344))     # stem
    line((664, 344), (744, 344))   # handlebar


def render(background):
    big = Image.new("RGB", (SIZE * SS, SIZE * SS), background)
    draw_bike(big)
    return big.resize((SIZE, SIZE), Image.Resampling.LANCZOS)


def main():
    out = Path(sys.argv[1])
    light = render((255, 255, 255))
    dark = render((0, 0, 0))
    light.save(out / "AppIcon.png", optimize=True)
    dark.save(out / "AppIcon-Dark.png", optimize=True)
    if len(sys.argv) > 2:
        preview = Image.new("RGB", (SIZE * 2 + 40, SIZE), (128, 128, 128))
        preview.paste(light, (0, 0))
        preview.paste(dark, (SIZE + 40, 0))
        preview.resize((preview.width // 2, preview.height // 2)).save(sys.argv[2])


if __name__ == "__main__":
    main()
