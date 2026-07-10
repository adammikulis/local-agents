#!/usr/bin/env python3
"""Rebuild addons/local_agents/assets/fonts/emoji.ttf — a tiny subset of Noto Color Emoji.

The voxel spawn palette (ui/SpawnPaletteHud.gd) renders its icon-only buttons with a bundled
emoji font. Bundling the full ~10 MB Noto Color Emoji is wasteful, so we ship only the handful
of glyphs the palette actually uses. This script is the canonical, reproducible build of that
subset: edit CODEPOINTS below (mirror KIND_SYMBOLS in SpawnPaletteHud.gd) and re-run it.

Usage:
    python3 scripts/build_emoji_subset.py [path/to/NotoColorEmoji.ttf]

Requires fonttools (`pip install fonttools`; provides pyftsubset). If the source font path is
not given, set NOTO_COLOR_EMOJI or drop NotoColorEmoji.ttf next to this script / in the repo
root. Grab the source from https://github.com/googlefonts/noto-emoji (fonts/NotoColorEmoji.ttf).
"""

import os
import subprocess
import sys

# One codepoint per palette glyph kept in the subset. Mirror KIND_SYMBOLS in
# ui/SpawnPaletteHud.gd; the life/prop kinds are swapped for 3D model thumbnails at runtime, so
# only their fallback glyphs + the abstract disaster glyphs need to live here.
CODEPOINTS = [
    0x2604,   # comet          (meteor)
    0x26A1,   # high voltage   (lightning)
    0x1F30A,  # water wave     (flood)
    0x1F30B,  # volcano        (volcano)
    0x1F331,  # seedling       (plant)
    0x1F3DA,  # derelict house (earthquake)
    0x1F407,  # rabbit         (fallback)
    0x1F41F,  # fish           (fallback)
    0x1F426,  # bird           (fallback)
    0x1F985,  # eagle          (vulture fallback)
    0x1F98A,  # fox            (fallback)
    0x1F9D1,  # person         (villager fallback)
    0x1F32A,  # cloud with tornado  (tornado)   -- added
    0x26C8,   # cloud w/ lightning + rain (thunderstorm) -- added
    0x1F300,  # cyclone        (hurricane)      -- added
]

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_PATH = os.path.join(REPO_ROOT, "addons", "local_agents", "assets", "fonts", "emoji.ttf")


def find_source() -> str:
    if len(sys.argv) > 1:
        return sys.argv[1]
    env = os.environ.get("NOTO_COLOR_EMOJI")
    if env:
        return env
    for cand in (
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "NotoColorEmoji.ttf"),
        os.path.join(REPO_ROOT, "NotoColorEmoji.ttf"),
    ):
        if os.path.exists(cand):
            return cand
    sys.exit(
        "Source Noto Color Emoji not found. Pass its path as an argument, set NOTO_COLOR_EMOJI, "
        "or place NotoColorEmoji.ttf beside this script. Get it from googlefonts/noto-emoji."
    )


def main() -> None:
    src = find_source()
    if not os.path.exists(src):
        sys.exit("Source font does not exist: %s" % src)
    unicodes = ",".join("U+%04X" % cp for cp in CODEPOINTS)
    cmd = [
        sys.executable, "-m", "fontTools.subset", src,
        "--output-file=%s" % OUT_PATH,
        "--unicodes=%s" % unicodes,
        # CBDT/CBLC (the color bitmap strikes) are subsetted down to just our glyphs, so the
        # bundled font stays a few tens of KB instead of the full ~10 MB source.
        "--notdef-outline",
        "--recalc-bounds",
        "--drop-tables+=DSIG",
    ]
    print("subsetting %d glyphs from %s" % (len(CODEPOINTS), src))
    subprocess.run(cmd, check=True)
    print("wrote %s (%d bytes)" % (OUT_PATH, os.path.getsize(OUT_PATH)))


if __name__ == "__main__":
    main()
