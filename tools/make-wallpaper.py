#!/usr/bin/env python3
"""Render the Ember wallpaper for every palette in manifest/palettes/.

WHY THIS EXISTS

A shipped photograph means a licence to carry, a megabyte in the repo, and a
background that fights whatever palette is selected. A wallpaper generated from
the palette costs a few tens of kilobytes, recolours with the theme, and has no
licence at all.

WHY IT RUNS HERE AND NOT ON THE INSTALLED MACHINE

The output is committed. Generating on the target would mean either an image
library or ImageMagick in core - tens of megabytes on every install, to draw a
gradient once. The developer runs this when a palette is added or changed; the
machine just gets a PNG.

Standard library only, deliberately: no Pillow, no numpy. PNG is a simple
container and zlib is in the stdlib, so the dependency-free version is about
thirty lines longer and costs nothing to keep working.

Usage:  python3 tools/make-wallpaper.py [--width W] [--height H] [--dither N]
"""

import argparse
import math
import os
import random
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PALETTE_DIR = os.path.join(ROOT, "manifest", "palettes")
OUT_DIR = os.path.join(ROOT, "config", "wallpapers")

# The Ember treatment: a dark diagonal fall with one soft accent glow in the
# upper left. Tuned so the glow reads as a light source rather than as a shape -
# raise GLOW_STRENGTH and it starts looking like a picture, which is not the job
# of a background you keep windows on top of.
GLOW_X, GLOW_Y = 0.22, 0.12
GLOW_RX, GLOW_RY = 1.05, 0.92
GLOW_STRENGTH = 0.20
ANGLE_DEG = 170.0
# Dither off, and rendered small on purpose. Measured, per palette:
#
#   1920x1080  dither 1.4   1362 KB
#   1280x720   dither 0.6    422 KB
#   1280x720   dither 0       31 KB
#
# Noise defeats PNG compression - it is the whole 44x difference. It exists to
# hide the banding that smooth 8-bit gradients show on a large screen, but
# swaybg scales this image up to the display with bilinear filtering, and that
# interpolation removes the banding for free. So the cheap fix is to render
# small and let the compositor do the smoothing, rather than to pay 1.3MB per
# palette for noise that scaling would have made redundant.
#
# Raise both if a future treatment has actual detail in it; a gradient has none.
DITHER = 0.0      # overridden by --dither


def parse_palette(path):
    colors = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            key, _, value = line.partition("=")
            colors[key.strip()] = value.strip()
    return colors


def rgb(value):
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


def write_png(path, width, height, rows):
    """rows is an iterable of bytearrays, one per scanline, RGB8."""
    raw = bytearray()
    for row in rows:
        raw.append(0)          # filter type 0 (None) - gradients compress fine
        raw.extend(row)

    def chunk(tag, data):
        out = struct.pack(">I", len(data)) + tag + data
        return out + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    with open(path, "wb") as fh:
        fh.write(b"\x89PNG\r\n\x1a\n")
        fh.write(chunk(b"IHDR", header))
        fh.write(chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        fh.write(chunk(b"IEND", b""))


def render(width, height, palette, seed):
    top = rgb(palette["mantle"])
    bottom = rgb(palette["crust"])
    glow = rgb(palette["accent"])

    # CSS angles run clockwise from "to top", so 170 degrees is almost straight
    # down with a slight lean. Project each pixel onto that axis once.
    theta = math.radians(ANGLE_DEG)
    ax, ay = math.sin(theta), -math.cos(theta)
    span = abs(ax) * width + abs(ay) * height
    ox = width if ax < 0 else 0.0
    oy = height if ay < 0 else 0.0

    cx, cy = GLOW_X * width, GLOW_Y * height
    rx, ry = GLOW_RX * width, GLOW_RY * height

    rand = random.Random(seed)
    for y in range(height):
        row = bytearray()
        dy = (y - oy) * ay
        ny = ((y - cy) / ry) ** 2
        for x in range(width):
            t = (dy + (x - ox) * ax) / span
            if t < 0.0:
                t = 0.0
            elif t > 1.0:
                t = 1.0

            d = math.sqrt(((x - cx) / rx) ** 2 + ny)
            if d < 1.0:
                f = 1.0 - d
                a = f * f * GLOW_STRENGTH      # quadratic falloff, no hard edge
            else:
                a = 0.0

            n = rand.uniform(-DITHER, DITHER)
            for i in range(3):
                base = top[i] + (bottom[i] - top[i]) * t
                v = base + (glow[i] - base) * a + n
                row.append(0 if v < 0 else (255 if v > 255 else int(v + 0.5)))
        yield row


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=720)
    ap.add_argument("--dither", type=float, default=None,
                    help="noise amplitude; 0 relies on the compositor's scaling instead")
    ap.add_argument("--only", help="render a single palette by id")
    args = ap.parse_args()
    if args.dither is not None:
        globals()["DITHER"] = args.dither

    if not os.path.isdir(PALETTE_DIR):
        sys.exit("no palettes at %s" % PALETTE_DIR)
    os.makedirs(OUT_DIR, exist_ok=True)

    names = sorted(f[:-len(".palette")] for f in os.listdir(PALETTE_DIR)
                   if f.endswith(".palette"))
    if args.only:
        names = [n for n in names if n == args.only]
        if not names:
            sys.exit("no such palette: %s" % args.only)

    for name in names:
        palette = parse_palette(os.path.join(PALETTE_DIR, name + ".palette"))
        missing = [k for k in ("mantle", "crust", "accent") if k not in palette]
        if missing:
            sys.exit("%s.palette is missing %s" % (name, ", ".join(missing)))
        out = os.path.join(OUT_DIR, name + ".png")
        # Seed from the name so a rebuild is byte-identical and does not show up
        # as a spurious diff.
        write_png(out, args.width, args.height,
                  render(args.width, args.height, palette, name))
        print("%-12s %s  %6.1f KB" % (name, out, os.path.getsize(out) / 1024.0))


if __name__ == "__main__":
    main()
