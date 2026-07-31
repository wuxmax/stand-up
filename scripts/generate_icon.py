#!/usr/bin/env python3
"""Generate the StandUp app icon PNGs (pure stdlib: zlib + struct).

Design: a bold white up-arrow rising from a desk surface, on the accent-blue
rounded square. Edges are anti-aliased via supersampling (no Pillow).
"""
import os
import struct
import zlib

OUT = os.path.join(os.path.dirname(__file__), "..", "StandUp", "Assets.xcassets", "AppIcon.appiconset")

SIZES = {
    "icon_16.png": 16,
    "icon_32.png": 32,
    "icon_64.png": 64,
    "icon_128.png": 128,
    "icon_256.png": 256,
    "icon_512.png": 512,
    "icon_1024.png": 1024,
}

# Accent orange-blue from AccentColor.colorset (sRGB ~0.176, 0.510, 0.894).
BG = (45, 130, 228)
FG = (255, 255, 255)

SS = 4  # supersampling factor for anti-aliasing


def write_png(path, width, height, rgba_rows):
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data +
                struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)  # 8-bit RGBA
    raw = b"".join(b"\x00" + row for row in rgba_rows)
    idat = zlib.compress(raw, 9)
    with open(path, "wb") as f:
        f.write(sig)
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", idat))
        f.write(chunk(b"IEND", b""))


# --- shape tests (32-unit design grid, y down, origin top-left) ---

def inside_rounded_rect(x, y, x0, y0, x1, y1, r):
    if x < x0 or x > x1 or y < y0 or y > y1:
        return False
    cx = min(max(x, x0 + r), x1 - r)
    cy = min(max(y, y0 + r), y1 - r)
    dx = x - cx
    dy = y - cy
    return dx * dx + dy * dy <= r * r


def _sign(px, py, ax, ay, bx, by):
    return (px - bx) * (ay - by) - (ax - bx) * (py - by)


def inside_triangle(x, y, ax, ay, bx, by, cx, cy):
    d1 = _sign(x, y, ax, ay, bx, by)
    d2 = _sign(x, y, bx, by, cx, cy)
    d3 = _sign(x, y, cx, cy, ax, ay)
    has_neg = d1 < 0 or d2 < 0 or d3 < 0
    has_pos = d1 > 0 or d2 > 0 or d3 > 0
    return not (has_neg and has_pos)


def inside_rect(x, y, x0, y0, x1, y1):
    return x0 <= x <= x1 and y0 <= y <= y1


def pixel_color(x, y):
    """Return (r, g, b, a) at design coordinate (x, y) in the 32-unit grid."""
    # Background: full-bleed rounded square, corner radius 8.
    if not inside_rounded_rect(x, y, 0, 0, 32, 32, 8):
        return (0, 0, 0, 0)
    r, g, b = BG

    # Desk surface: a white rounded bar near the bottom.
    if inside_rounded_rect(x, y, 4, 25, 28, 28, 1.5):
        r, g, b = FG

    # Up arrow (white), apex near the top, shaft rising from just above the desk.
    # Head triangle.
    if inside_triangle(x, y, 16, 6, 7, 15, 25, 15):
        r, g, b = FG
    # Shaft.
    if inside_rect(x, y, 13, 15, 19, 23):
        r, g, b = FG
    # Blend the shaft into the head base smoothly (overlap is fine; both white).

    return (r, g, b, 255)


def render(px):
    """Render the icon at px x px, anti-aliased via SS-fold supersampling."""
    sub = px * SS
    scale = 32.0 / sub
    rows = []
    for oy in range(px):
        row = bytearray()
        for ox in range(px):
            sr = sg = sb = sa = 0
            for j in range(SS):
                gy = (oy * SS + j + 0.5) * scale
                for i in range(SS):
                    gx = (ox * SS + i + 0.5) * scale
                    r, g, b, a = pixel_color(gx, gy)
                    # premultiplied accumulate
                    sr += r * a
                    sg += g * a
                    sb += b * a
                    sa += a
            n = SS * SS
            if sa > 0:
                r = sr // sa
                g = sg // sa
                b = sb // sa
                a = sa // n
            else:
                r = g = b = a = 0
            row += bytes((r, g, b, a))
        rows.append(bytes(row))
    return rows


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, px in SIZES.items():
        path = os.path.join(OUT, name)
        write_png(path, px, px, render(px))
        print(f"Wrote {name} ({px}x{px})")
    print("Done.")


if __name__ == "__main__":
    main()