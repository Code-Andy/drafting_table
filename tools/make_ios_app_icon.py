#!/usr/bin/env python3
"""Generate the iOS AppIcon asset set from the existing bold compass art."""

from pathlib import Path

from PIL import Image, ImageChops, ImageOps


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "tools" / "icon_coarse_2.png"
APPICON_DIR = ROOT / "platforms" / "ipad" / "Assets.xcassets" / "AppIcon.appiconset"
BACKGROUND = (244, 236, 218)
INK = (24, 30, 34)

SIZES = {
    "AppIcon-20.png": 20,
    "AppIcon-29.png": 29,
    "AppIcon-40.png": 40,
    "AppIcon-40@2x.png": 80,
    "AppIcon-20@3x.png": 60,
    "AppIcon-29@2x.png": 58,
    "AppIcon-29@3x.png": 87,
    "AppIcon-40@3x.png": 120,
    "AppIcon-60@2x.png": 120,
    "AppIcon-60@3x.png": 180,
    "AppIcon-76.png": 76,
    "AppIcon-76@2x.png": 152,
    "AppIcon-83.5@2x.png": 167,
    "AppIcon-1024.png": 1024,
}


def normalized_master() -> Image.Image:
    source = Image.open(SOURCE).convert("RGB")
    white = Image.new("RGB", source.size, "white")
    difference = ImageChops.difference(source, white).convert("L")
    mask = difference.point(lambda value: 255 if value > 18 else 0)
    bounds = mask.getbbox()
    if bounds is None:
        raise RuntimeError(f"No non-white artwork found in {SOURCE}")

    ink_mask = ImageOps.invert(source.convert("L")).crop(bounds)
    canvas = Image.new("RGB", (1024, 1024), BACKGROUND)
    available = 860
    scale = min(available / ink_mask.width, available / ink_mask.height)
    target = (
        max(1, round(ink_mask.width * scale)),
        max(1, round(ink_mask.height * scale)),
    )
    ink_mask = ink_mask.resize(target, Image.Resampling.LANCZOS)
    position = ((1024 - target[0]) // 2, (1024 - target[1]) // 2)
    canvas.paste(INK, position, ink_mask)
    return canvas


def main() -> None:
    APPICON_DIR.mkdir(parents=True, exist_ok=True)
    master = normalized_master()
    for filename, pixels in SIZES.items():
        image = master if pixels == 1024 else master.resize(
            (pixels, pixels), Image.Resampling.LANCZOS
        )
        image.save(APPICON_DIR / filename, format="PNG", optimize=True)
    print(f"Generated {len(SIZES)} icons in {APPICON_DIR}")


if __name__ == "__main__":
    main()
