#!/usr/bin/env python3
"""Generate the StandUp app icon PNGs (pure stdlib: zlib + struct)."""
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

# Accent orange from AccentColor.colorset (sRGB ~0.176, 0.510, 0.894)
BG = (45, 130, 228)
FG = (255, 255, 255)


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


def in_rounded_rect(x, y, w, h, r):
    # Returns True if (x,y) is inside a rounded rect of size w x h with corner radius r.
    if x < r and y < r:
        return (r - x) ** 2 + (r - y) ** 2 <= r * r
    if x >= w - r and y < r:
        return (x - (w - r - 1)) ** 2 + (r - y) ** 2 <= r * r
    if x < r and y >= h - r:
        return (r - x) ** 2 + (y - (h - r - 1)) ** 2 <= r * r
    if x >= w - r and y >= h - r:
        return (x - (w - r - 1)) ** 2 + (y - (h - r - 1)) ** 2 <= r * r
    return True


def render(px):
    """Render the icon at px x px. Design grid is 32 units."""
    u = px / 32.0
    r = px * 0.22
    rows = []
    for y in range(px):
        row = bytearray()
        for x in range(px):
            if not in_rounded_rect(x, y, px, px, r):
                row += bytes((0, 0, 0, 0))
                continue
            # Decide glyph pixels. Use a simple "standing figure + up arrow".
            col = BG
            # Head
            hx0, hx1 = 13 * u, 18 * u
            hy0, hy1 = 24 * u, 28 * u
            if hx0 <= x < hx1 and hy0 <= y < hy1:
                col = FG
            # Body
            bx0, bx1 = 13 * u, 19 * u
            by0, by1 = 12 * u, 22 * u
            if bx0 <= x < bx1 and by0 <= y < by1:
                col = FG
            # Legs
            if 13 * u <= x < 15.5 * u and 4 * u <= y < 12 * u:
                col = FG
            if 16.5 * u <= x < 19 * u and 4 * u <= y < 12 * u:
                col = FG
            # Up arrow
            if 24 * u <= x < 28 * u and 22 * u <= y < 25 * u:
                col = FG
            if 25.2 * u <= x < 26.8 * u and 25 * u <= y < 28 * u:
                col = FG
            row += bytes((col[0], col[1], col[2], 255))
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