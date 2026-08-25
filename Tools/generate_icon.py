#!/usr/bin/env python3
"""
generate_icon.py — renders the Salman Mac Cleaner app icon at every size
required by Assets.xcassets/AppIcon.appiconset using only the Python standard
library (zlib + struct). Run it once and the PNG files become permanent parts
of the repository.

Usage:
    python3 Tools/generate_icon.py
"""

from __future__ import annotations

import math
import os
import struct
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONSET = os.path.join(ROOT, "SalmanMacCleaner", "Assets.xcassets", "AppIcon.appiconset")

# Rounded-rect geometry (unit square)
HALF = 0.5            # half-size of the rounded rect
RADIUS = 0.225        # corner radius
INNER = HALF - RADIUS  # straight-edge half-extent

# Pixel-softness for anti-aliasing (fraction of the icon edge)
SOFT = 1.0 / 256.0


def clamp01(value: float) -> float:
    return max(0.0, min(1.0, value))


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def rounded_rect_coverage(u: float, v: float) -> float:
    """Coverage (0..1, anti-aliased) of a rounded rect centered at (0.5, 0.5)."""
    qx = abs(u - 0.5)
    qy = abs(v - 0.5)
    dx = qx - INNER
    dy = qy - INNER
    if dx > 0.0 and dy > 0.0:
        dist = (dx * dx + dy * dy) ** 0.5 - RADIUS
    else:
        dist = max(dx, dy) - RADIUS
    return clamp01(0.5 - dist / SOFT)


def segment_distance(px: float, py: float, x1: float, y1: float, x2: float, y2: float) -> float:
    dx = x2 - x1
    dy = y2 - y1
    length_sq = dx * dx + dy * dy
    if length_sq == 0.0:
        return ((px - x1) ** 2 + (py - y1) ** 2) ** 0.5
    t = clamp01(((px - x1) * dx + (py - y1) * dy) / length_sq)
    return ((px - (x1 + t * dx)) ** 2 + (py - (y1 + t * dy)) ** 2) ** 0.5


def sample_icon(u: float, v: float) -> tuple[float, float, float, float]:
    """Sample the icon in unit coordinates. u = horizontal, v = vertical (top = 0)."""
    alpha = rounded_rect_coverage(u, v)
    if alpha <= 0.0:
        return (0.0, 0.0, 0.0, 0.0)

    # ---- vertical gradient background: blue -> purple, with a soft top glow ----
    t = v
    bg = (
        lerp(0.18, 0.45, t),
        lerp(0.42, 0.26, t),
        lerp(0.92, 0.78, t),
    )
    glow = max(0.0, 1.0 - ((u - 0.5) ** 2 + (v - 0.25) ** 2) * 3.2)
    bg = (
        bg[0] + 0.10 * glow,
        bg[1] + 0.12 * glow,
        bg[2] + 0.06 * glow,
    )

    # ---- sweeping cleaning arc (white ring segment, top-right sweep) ----
    radial = ((u - 0.5) ** 2 + (v - 0.52) ** 2) ** 0.5
    arc_band = max(0.0, 1.0 - abs(radial - 0.315) / 0.028)
    angle = ((u - 0.5) / max(radial, 1e-6), (v - 0.52) / max(radial, 1e-6))
    theta = math.atan2(angle[1], angle[0])  # -pi..pi, 0 = right
    sweep = clamp01((math.pi * 0.82 - theta) / (math.pi * 0.55))
    arc = arc_band * sweep
    sparkle = (1.0, 1.0, 1.0)

    # ---- central shield ----
    su = (u - 0.5) / 0.31
    sv = (v - 0.53) / 0.37
    shield = 0.0
    if abs(su) <= 1.0 and -1.0 <= sv <= 1.0:
        top = 1.0 - abs(su) * 1.12
        bottom = 0.40 - su * su * 0.55
        inside = sv <= top and sv >= -bottom
        if inside:
            shield = 1.0
            # anti-alias near the shield silhouette
            d_top = (top - sv)
            d_side = 1.0 - abs(su)
            d_bottom = (sv + bottom)
            d = min(d_top, d_side, d_bottom)
            shield = clamp01(0.5 + d / (SOFT * 1.4))
    shield_color = (0.97, 0.98, 1.0)

    # ---- green check mark inside the shield ----
    cu = su * 0.31
    cv = sv * 0.37
    # two legs, sized to fit inside the shield
    legs = [
        (-0.24, 0.00, -0.02, 0.22),
        (-0.02, 0.22, 0.26, -0.12),
    ]
    check = 0.0
    for (x1, y1, x2, y2) in legs:
        dist = segment_distance(cu, cv, x1, y1, x2, y2)
        check = max(check, clamp01(0.5 + (0.026 - dist) / (SOFT * 2.0)))
    check_color = (0.13, 0.75, 0.42)

    # ---- composite ----
    r, g, b = bg
    if arc > 0.0:
        r = r * (1 - arc) + sparkle[0] * arc
        g = g * (1 - arc) + sparkle[1] * arc
        b = b * (1 - arc) + sparkle[2] * arc
    if shield > 0.0:
        r = r * (1 - shield) + shield_color[0] * shield
        g = g * (1 - shield) + shield_color[1] * shield
        b = b * (1 - shield) + shield_color[2] * shield
    if check > 0.0 and shield > 0.5:
        r = r * (1 - check) + check_color[0] * check
        g = g * (1 - check) + check_color[1] * check
        b = b * (1 - check) + check_color[2] * check

    return (clamp01(r), clamp01(g), clamp01(b), alpha)


def render(size: int) -> bytes:
    raw = bytearray()
    for y in range(size):
        raw.append(0)  # PNG filter: None
        v = (y + 0.5) / size
        for x in range(size):
            u = (x + 0.5) / size
            r, g, b, a = sample_icon(u, v)
            raw += bytes((int(r * 255), int(g * 255), int(b * 255), int(a * 255)))
    return bytes(raw)


def png_chunk(tag: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


def write_png(path: str, size: int) -> None:
    raw = render(size)
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)  # 8-bit RGBA
    png = b"\x89PNG\r\n\x1a\n"
    png += png_chunk(b"IHDR", ihdr)
    png += png_chunk(b"IDAT", zlib.compress(raw, 9))
    png += png_chunk(b"IEND", b"")
    with open(path, "wb") as handle:
        handle.write(png)
    print(f"  wrote {os.path.relpath(path, ROOT)} ({size}x{size}, {os.path.getsize(path)} bytes)")


def main() -> None:
    sizes = [16, 32, 128, 256, 512]
    for size in sizes:
        write_png(os.path.join(ICONSET, f"icon_{size}.png"), size)
        write_png(os.path.join(ICONSET, f"icon_{size}@2x.png"), size * 2)


if __name__ == "__main__":
    main()
