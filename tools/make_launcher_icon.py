"""Generate adaptive-icon foreground PNGs from icon.png.

Trims the near-white background to transparent, then renders the trimmed
subject centered on a 108dp canvas at the standard adaptive-icon safe-zone
size (66/108 of the canvas). Writes density-specific PNGs into
drawable-{m,h,xh,xxh,xxxh}dpi/ic_launcher_foreground.png.
"""
import os
import sys
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "tools/icon_coarse_2.png")
RES = os.path.join(ROOT, "app", "src", "main", "res")

DENSITIES = [
    ("drawable-mdpi",    108),
    ("drawable-hdpi",    162),
    ("drawable-xhdpi",   216),
    ("drawable-xxhdpi",  324),
    ("drawable-xxxhdpi", 432),
]

SAFE_ZONE_FRACTION = 66.0 / 108.0
WHITE_THRESHOLD = 240


def to_transparent(img: Image.Image) -> Image.Image:
    """Replace near-white pixels with transparency, preserving anti-alias."""
    img = img.convert("RGBA")
    px = img.load()
    w, h = img.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if r >= WHITE_THRESHOLD and g >= WHITE_THRESHOLD and b >= WHITE_THRESHOLD:
                px[x, y] = (r, g, b, 0)
            else:
                m = max(r, g, b)
                if m > WHITE_THRESHOLD:
                    fade = int(255 * (255 - m) / (255 - WHITE_THRESHOLD))
                    if fade < a:
                        px[x, y] = (r, g, b, fade)
    return img


def main() -> int:
    if not os.path.exists(SRC):
        print(f"missing source: {SRC}", file=sys.stderr)
        return 1

    src = Image.open(SRC)
    src = to_transparent(src)
    bbox = src.getbbox()
    if bbox is None:
        print("source image is fully transparent", file=sys.stderr)
        return 1
    cropped = src.crop(bbox)

    cw, ch = cropped.size
    side = max(cw, ch)
    squared = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    squared.paste(cropped, ((side - cw) // 2, (side - ch) // 2))

    for subdir, canvas_size in DENSITIES:
        safe = int(round(canvas_size * SAFE_ZONE_FRACTION))
        resized = squared.resize((safe, safe), Image.LANCZOS)
        canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
        off = (canvas_size - safe) // 2
        canvas.paste(resized, (off, off), resized)
        out_dir = os.path.join(RES, subdir)
        os.makedirs(out_dir, exist_ok=True)
        out_path = os.path.join(out_dir, "ic_launcher_foreground.png")
        canvas.save(out_path, "PNG", optimize=True)
        print(f"wrote {out_path} ({canvas_size}x{canvas_size})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
