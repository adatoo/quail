#!/usr/bin/env python3
"""Renders Quail's app icon from Design/AppIcon-source.png into the asset catalog.

    python3 Design/make-icon.py        (needs Pillow: pip3 install pillow)

macOS app icons are a rounded square ("squircle") 824 px wide on a 1024 px canvas, with
a soft shadow beneath; the system does not add the shape for a plain .appiconset. The source
is a bird on a flat yellow field, so the field fills the squircle and the bird sits inside it.
"""
from pathlib import Path

from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Design" / "AppIcon-source.png"
SET = ROOT / "Quail" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"

CANVAS, BODY = 1024, 824
BIRD_SCALE = 0.92  # of the body: leaves the wing tips clear of the corners
SS = 4  # supersampling for a clean edge


def squircle_mask(size: int, n: float = 5.0) -> Image.Image:
    """A superellipse |x|^n + |y|^n <= 1, close to Apple's icon shape."""
    big = size * SS
    mask = Image.new("L", (big, big), 0)
    px = mask.load()
    half = big / 2
    for y in range(big):
        ny = abs((y + 0.5 - half) / half) ** n
        for x in range(big):
            if abs((x + 0.5 - half) / half) ** n + ny <= 1:
                px[x, y] = 255
    return mask.resize((size, size), Image.LANCZOS)


def master() -> Image.Image:
    src = Image.open(SOURCE).convert("RGB")
    field = src.getpixel((4, 4))
    body = Image.new("RGB", (BODY, BODY), field)
    bird = src.resize((round(BODY * BIRD_SCALE),) * 2, Image.LANCZOS)
    offset = (BODY - bird.width) // 2
    body.paste(bird, (offset, offset))

    mask = squircle_mask(BODY)
    out = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))

    shadow = Image.new("L", (CANVAS, CANVAS), 0)
    shadow.paste(mask, ((CANVAS - BODY) // 2, (CANVAS - BODY) // 2 + 10))
    shadow = shadow.filter(ImageFilter.GaussianBlur(14)).point(lambda v: int(v * 0.30))
    out.paste(Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 255)), (0, 0), shadow)

    placed = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    placed.paste(body, ((CANVAS - BODY) // 2,) * 2)
    alpha = Image.new("L", (CANVAS, CANVAS), 0)
    alpha.paste(mask, ((CANVAS - BODY) // 2,) * 2)
    placed.putalpha(alpha)
    out.alpha_composite(placed)
    return out


def main() -> None:
    icon = master()
    images = []
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
            icon.resize((points * scale,) * 2, Image.LANCZOS).save(SET / name)
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})
    import json

    (SET / "Contents.json").write_text(
        json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n"
    )
    print(f"wrote {len(images)} icons to {SET.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
