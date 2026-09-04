#!/usr/bin/env python3
"""Convert Drafting Table Android VectorDrawable icons into SVG imagesets.

The Android source is the visual authority for the iPad chrome.  The vectors
are intentionally kept as 24×24 path geometry and use ``currentColor`` so
UIKit can tint the resulting template images.  This script is deliberately
small and deterministic: it is useful when the upstream icon set changes and
also documents the Android-to-SVG attribute mapping.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import xml.etree.ElementTree as ET
from pathlib import Path


ANDROID = "http://schemas.android.com/apk/res/android"
NS = "{" + ANDROID + "}"


def attr(element: ET.Element, name: str, default: str | None = None) -> str | None:
    return element.get(NS + name, default)


def alpha_from_color(value: str | None) -> float:
    """Return Android #AARRGGBB/#RGB alpha; #000 means opaque black."""
    if not value:
        return 1.0
    value = value.strip()
    if value.startswith("#"):
        digits = value[1:]
        if len(digits) == 8:
            return int(digits[:2], 16) / 255.0
        if len(digits) == 4:
            return int(digits[0] * 2, 16) / 255.0
    return 1.0


def color_role(value: str | None, *, fill: bool) -> tuple[str, float | None]:
    """Map Android colors to template currentColor plus source alpha."""
    if not value or value.lower().endswith("00000000"):
        return ("none" if fill else "none", None)
    # Android vectors in this repository deliberately use black as the ink
    # color.  Preserve alpha while replacing black with the template color.
    alpha = alpha_from_color(value)
    return "currentColor", (None if math.isclose(alpha, 1.0) else alpha)


def num(value: str | None, fallback: float = 0.0) -> float:
    try:
        return float(value) if value is not None else fallback
    except (TypeError, ValueError):
        return fallback


def group_transform(group: ET.Element) -> str | None:
    sx = num(attr(group, "scaleX"), 1.0)
    sy = num(attr(group, "scaleY"), 1.0)
    px = num(attr(group, "pivotX"), 0.0)
    py = num(attr(group, "pivotY"), 0.0)
    rotation = num(attr(group, "rotation"), 0.0)
    if math.isclose(sx, 1.0) and math.isclose(sy, 1.0) and math.isclose(rotation, 0.0):
        return None
    pieces: list[str] = []
    # Android applies scale/rotation around the declared pivot.  SVG applies
    # transform functions right-to-left, so this list mirrors that sequence.
    pieces.append(f"translate({px:g} {py:g})")
    if not math.isclose(rotation, 0.0):
        pieces.append(f"rotate({rotation:g})")
    if not (math.isclose(sx, 1.0) and math.isclose(sy, 1.0)):
        pieces.append(f"scale({sx:g} {sy:g})")
    pieces.append(f"translate({-px:g} {-py:g})")
    return " ".join(pieces)


def path_element(path: ET.Element, inherited_transform: str | None = None) -> str:
    data = attr(path, "pathData", "") or ""
    pieces = [f'  <path d="{data}"']
    stroke, stroke_alpha = color_role(attr(path, "strokeColor"), fill=False)
    fill, fill_alpha = color_role(attr(path, "fillColor"), fill=True)
    pieces.append(f' stroke="{stroke}"')
    pieces.append(f' fill="{fill}"')
    width = attr(path, "strokeWidth")
    if width is not None:
        pieces.append(f' stroke-width="{num(width):g}"')
    cap = attr(path, "strokeLineCap")
    join = attr(path, "strokeLineJoin")
    if cap:
        pieces.append(f' stroke-linecap="{cap}"')
    if join:
        pieces.append(f' stroke-linejoin="{join}"')
    stroke_alpha_attr = attr(path, "strokeAlpha")
    if stroke_alpha is not None:
        pieces.append(f' stroke-opacity="{stroke_alpha:g}"')
    if stroke_alpha_attr is not None:
        pieces.append(f' stroke-opacity="{num(stroke_alpha_attr):g}"')
    fill_alpha_attr = attr(path, "fillAlpha")
    if fill_alpha is not None:
        pieces.append(f' fill-opacity="{fill_alpha:g}"')
    if fill_alpha_attr is not None:
        pieces.append(f' fill-opacity="{num(fill_alpha_attr):g}"')
    if inherited_transform:
        pieces.append(f' transform="{inherited_transform}"')
    pieces.append("/>")
    return "".join(pieces)


def emit_children(parent: ET.Element, transforms: list[str]) -> list[str]:
    lines: list[str] = []
    for child in parent:
        tag = child.tag.rsplit("}", 1)[-1]
        if tag == "path":
            transform = " ".join(t for t in transforms if t) or None
            lines.append(path_element(child, transform))
        elif tag == "group":
            transform = group_transform(child)
            next_transforms = transforms + ([transform] if transform else [])
            lines.extend(emit_children(child, next_transforms))
    return lines


def convert(source: Path, output_root: Path, name: str) -> None:
    root = ET.parse(source).getroot()
    width = attr(root, "width", "24dp") or "24dp"
    height = attr(root, "height", "24dp") or "24dp"
    viewport_w = num(attr(root, "viewportWidth"), 24.0)
    viewport_h = num(attr(root, "viewportHeight"), 24.0)
    width = re.sub(r"dp$", "", width)
    height = re.sub(r"dp$", "", height)
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!-- Generated from the upstream Android VectorDrawable; keep as a template asset. -->',
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {viewport_w:g} {viewport_h:g}">',
        *emit_children(root, []),
        '</svg>',
        '',
    ]
    imageset = output_root / f"dt_{name}.imageset"
    imageset.mkdir(parents=True, exist_ok=True)
    (imageset / f"dt_{name}.svg").write_text("\n".join(lines), encoding="utf-8")
    contents = {
        "images": [{"filename": f"dt_{name}.svg", "idiom": "universal", "scale": "1x"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"template-rendering-intent": "template"},
    }
    (imageset / "Contents.json").write_text(
        json.dumps(contents, indent=2) + "\n", encoding="utf-8"
    )


DEFAULT_NAMES = (
    "menu", "pen", "eraser", "bucket", "shade", "line", "rect", "circle",
    "ellipse", "select", "lasso", "layers", "pages", "color", "reset_view",
    "undo", "redo", "eye", "eye_off", "more", "drag_handle", "plus",
    "plus_vector", "vector_select", "grid", "snap", "eyedropper", "docs",
)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True, help="Android drawable directory")
    parser.add_argument("--output", type=Path, required=True, help="Chrome asset directory")
    parser.add_argument("names", nargs="*", default=DEFAULT_NAMES)
    args = parser.parse_args()
    for name in args.names:
        convert(args.source / f"ic_{name}.xml", args.output, name)


if __name__ == "__main__":
    main()
