#!/usr/bin/env python3
"""Draws Pict's app icon and writes the asset catalog.

Procedural rather than a checked-in binary, so the icon is a thing you can read
and argue with. Change a number here, re-run, and every size is regenerated in
step — which is the whole reason the sizes cannot drift apart.

    python3 scripts/make-app-icon.py

Writes App/Pict/Assets.xcassets/AppIcon.appiconset/*.png and its Contents.json.

No dependencies on purpose: no Pillow, no ImageMagick, no SVG rasteriser. Shapes
come from signed-distance functions, anti-aliased by taking the coverage of a
one-pixel band across each boundary, and the PNGs are encoded here with zlib. So
this runs anywhere Python does, including the toolchain-free environment the rest
of this repo was written in.

## The design, and why this one

Three bright rounded tiles, fanned like held cards, on a violet plate.

The family already has a visual language and it is not lettering or glyphs: both
Jetty and Top Drawer are built around *small colourful app tiles* — a pier with
three of them sitting on it, a drawer standing open on a grid of them. Those
tiles are the thing all four apps are actually about, so Pict shows them too, in
the same red/green/blue.

Fanned rather than stacked or gridded because Pict's verb is **choosing**: a fan
is a hand of cards offered up, which is what the editor does. Violet because Zap
already owns blue and the other two are wood-brown, so this is the one hue that
tells the four apart in a Dock.

Full-bleed squircle: macOS 26 masks every app icon into one regardless
(`UNJAILED.md §1`), so a margin would only become a smaller margin. The 2% inset
keeps it from reading as a hard-cropped square on macOS 13–15, where nothing is
masked.

Three tiles is the legibility budget. At 16 px each is about four pixels across,
which is enough to read as "three coloured things" and not enough for a fourth.
"""

import math
import os
import struct
import zlib

# --- Palette -----------------------------------------------------------------
# Plate: violet. Zap is blue, Jetty and Top Drawer are wood; this is the hue that
# is still free, and it stays distinct from all three at 16 px.
PLATE_TOP = (0x8B, 0x5C, 0xF6)
PLATE_BOTTOM = (0x4C, 0x2C, 0xC9)

# The tiles, in the same primaries Jetty's pier and Top Drawer's drawer use.
# Each is (top, bottom) so the tiles are lit like the plate rather than flat.
TILE_BLUE = ((0x60, 0xA5, 0xFA), (0x25, 0x63, 0xEB))
TILE_GREEN = ((0x4A, 0xDE, 0x80), (0x16, 0xA3, 0x4A))
TILE_CORAL = ((0xFB, 0x7F, 0x6A), (0xE1, 0x1D, 0x48))

INSET = 0.02          # fraction of the canvas left clear on every side
SQUIRCLE_N = 5.0      # superellipse exponent; ~5 approximates Apple's corner
# macOS wants each nominal size at 1× and 2×. Ten entries over seven distinct
# pixel sizes — `icon_16x16@2x` and `icon_32x32@1x` are both 32 px and both get
# written, rather than sharing one file. That is what Xcode itself emits and what
# the three sibling apps ship; `actool` wants a file per entry.
CONTENTS = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
            (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

# The plate's violet, for anything tinted by the system accent.
ACCENT = (0x8B / 255.0, 0x5C / 255.0, 0xF6 / 255.0)

# The fan hinges about a pivot *below* the tiles, the way a hand of cards does —
# rotating each tile about its own centre instead splays it at the bottom as well
# as the top, which reads as three tiles falling over rather than one fan.
FAN_PIVOT = (0.500, 1.150)
FAN_RADIUS = 0.660    # pivot to tile centre
FAN_SPREAD = 13.5     # degrees off vertical for the outer two
# A distant pivot and a shallow spread, so the three overlap as a stack rather
# than splaying into a bow tie. Wider reads squat in a square; tighter and the
# three collapse into one lumpy mass instead of a choice between three things.
# Drawn back to front: the outer two, then the chosen one on top.
FAN = [(-FAN_SPREAD, TILE_BLUE), (FAN_SPREAD, TILE_GREEN), (0.0, TILE_CORAL)]
TILE_HALF = 0.156     # half-extent of a tile
TILE_RADIUS = 0.052   # its corner radius


def clamp(value, low=0.0, high=1.0):
    return low if value < low else high if value > high else value


def coverage(distance, aa=1.0):
    """Coverage of a pixel straddling an edge `distance` pixels away.

    Negative is inside. One-pixel band — wider blurs a 16 px icon, narrower makes
    its diagonals crawl.
    """
    return clamp(0.5 - distance / aa)


def squircle_distance(x, y, half):
    """Approximate signed distance to the superellipse of half-extent `half`.

    A superellipse has no closed-form distance, so this normalises the implicit
    field by its own exponent — accurate near the boundary, which is the only
    place anti-aliasing looks.
    """
    nx, ny = abs(x) / half, abs(y) / half
    if nx == 0.0 and ny == 0.0:
        return -half
    field = nx ** SQUIRCLE_N + ny ** SQUIRCLE_N
    return (field ** (1.0 / SQUIRCLE_N) - 1.0) * half


def rounded_box_distance(px, py, half, radius):
    """Exact signed distance to a rounded square centred on the origin."""
    qx = abs(px) - half + radius
    qy = abs(py) - half + radius
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    return outside + min(max(qx, qy), 0.0) - radius


def rotated(px, py, degrees):
    """The point in the tile's own frame, so one box SDF serves every angle."""
    if degrees == 0.0:
        return px, py
    a = math.radians(-degrees)
    c, s = math.cos(a), math.sin(a)
    return px * c - py * s, px * s + py * c


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def over(dst, src, alpha):
    """Source-over composite of a solid colour at `alpha` onto `dst`."""
    return tuple(dst[i] + (src[i] - dst[i]) * alpha for i in range(3))


def render(size):
    """One RGBA image, as a flat bytearray."""
    half = size * (0.5 - INSET)
    centre = size / 2.0
    tile_half = TILE_HALF * size
    tile_radius = TILE_RADIUS * size
    # Shadows scale with the icon but never go below a pixel, or they vanish
    # entirely at 16 px and the tiles lose their separation.
    shadow_drop = max(0.006 * size, 0.6)
    shadow_soft = max(0.030 * size, 1.0)

    # Swing each tile out from the pivot, so the fan opens from one hinge.
    tiles = []
    for angle, colour in FAN:
        a = math.radians(angle)
        cx = (FAN_PIVOT[0] + FAN_RADIUS * math.sin(a)) * size
        cy = (FAN_PIVOT[1] - FAN_RADIUS * math.cos(a)) * size
        tiles.append((cx, cy, angle, colour))

    pixels = bytearray(size * size * 4)
    for py in range(size):
        y = py + 0.5
        row = py * size * 4
        for px in range(size):
            x = px + 0.5

            plate = coverage(squircle_distance(x - centre, y - centre, half))
            if plate <= 0.0:
                continue                      # outside the plate; stays clear

            # Plate: vertical gradient with a soft sheen toward the top-left, so
            # it reads as lit rather than as flat paint.
            colour = list(mix(PLATE_TOP, PLATE_BOTTOM, y / size))
            sheen = clamp(1.0 - math.hypot(x - 0.30 * size, y - 0.20 * size) / (0.88 * size))
            colour = [c + (255.0 - c) * 0.15 * sheen * sheen for c in colour]

            for tx, ty, angle, (tile_top, tile_bottom) in tiles:
                # Shadow first, offset down and softened over several pixels, so
                # a tile in front of another is legible as being in front.
                sx, sy = rotated(x - tx, y - (ty + shadow_drop), angle)
                shade = clamp(-rounded_box_distance(sx, sy, tile_half, tile_radius)
                              / shadow_soft + 0.5)
                if shade > 0.0:
                    colour = over(colour, (0.0, 0.0, 0.0), 0.30 * shade)

                rx, ry = rotated(x - tx, y - ty, angle)
                face = coverage(rounded_box_distance(rx, ry, tile_half, tile_radius))
                if face > 0.0:
                    # Gradient runs along the tile's own axis, so a rotated tile
                    # is lit consistently with an upright one.
                    lit = mix(tile_top, tile_bottom,
                              clamp((ry + tile_half) / (2.0 * tile_half)))
                    colour = over(colour, lit, face)

            i = row + px * 4
            pixels[i] = int(round(clamp(colour[0], 0.0, 255.0)))
            pixels[i + 1] = int(round(clamp(colour[1], 0.0, 255.0)))
            pixels[i + 2] = int(round(clamp(colour[2], 0.0, 255.0)))
            pixels[i + 3] = int(round(255 * plate))
    return pixels


def write_png(path, size, pixels):
    """Minimal RGBA8 PNG: no interlacing, filter 0 on every scanline."""
    raw = bytearray()
    stride = size * 4
    for py in range(size):
        raw.append(0)
        raw += pixels[py * stride:(py + 1) * stride]

    def chunk(kind, payload):
        return (struct.pack(">I", len(payload)) + kind + payload
                + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as handle:
        handle.write(png)


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    catalog = os.path.join(root, "App", "Pict", "Assets.xcassets")
    iconset = os.path.join(catalog, "AppIcon.appiconset")
    accent = os.path.join(catalog, "AccentColor.colorset")
    os.makedirs(iconset, exist_ok=True)
    os.makedirs(accent, exist_ok=True)

    # Render each distinct pixel size once, then write it under every name that
    # needs it — ten files, seven renders.
    drawn = {}
    for nominal, scale in CONTENTS:
        pixels = nominal * scale
        if pixels not in drawn:
            drawn[pixels] = render(pixels)
        name = f"icon_{nominal}x{nominal}@{scale}x.png"
        write_png(os.path.join(iconset, name), pixels, drawn[pixels])
        print(f"  {name} ({pixels}px)")

    images = ',\n'.join(
        '    {\n'
        '      "idiom" : "mac",\n'
        f'      "size" : "{nominal}x{nominal}",\n'
        f'      "scale" : "{scale}x",\n'
        f'      "filename" : "icon_{nominal}x{nominal}@{scale}x.png"\n'
        '    }'
        for nominal, scale in CONTENTS)
    write_text(os.path.join(iconset, "Contents.json"),
               '{\n  "images" : [\n' + images + '\n  ],\n'
               '  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')

    write_text(os.path.join(accent, "Contents.json"),
               '{\n  "colors" : [\n    {\n      "color" : {\n'
               '        "color-space" : "srgb",\n'
               '        "components" : { "alpha" : "1.000", '
               f'"blue" : "{ACCENT[2]:.3f}", "green" : "{ACCENT[1]:.3f}", '
               f'"red" : "{ACCENT[0]:.3f}" }}\n'
               '      },\n      "idiom" : "universal"\n    }\n  ],\n'
               '  "info" : { "author" : "xcode", "version" : 1 }\n}\n')

    write_text(os.path.join(catalog, "Contents.json"),
               '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')
    print("  Contents.json ×3")


def write_text(path, body):
    with open(path, "w") as handle:
        handle.write(body)


if __name__ == "__main__":
    main()
