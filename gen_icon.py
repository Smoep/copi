#!/usr/bin/env python3
"""Generate Copi's two-page Liquid Glass macOS app icon."""

import os

from PIL import Image, ImageDraw, ImageFilter


ICON_DIR = "copi/Assets.xcassets/AppIcon.appiconset"
SIZES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def vertical_gradient(size, top, bottom):
    layer = Image.new("RGBA", (size, size))
    pixels = layer.load()
    for y in range(size):
        t = y / max(1, size - 1)
        color = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(4))
        for x in range(size):
            pixels[x, y] = color
    return layer


def rounded_mask(size, box, radius):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def masked_alpha(alpha, mask):
    return Image.composite(alpha, Image.new("L", alpha.size, 0), mask)


def glass_page(image, box, radius, top, bottom, outline, shadow_alpha):
    size = image.width
    mask = rounded_mask(size, box, radius)

    shadow = Image.new("RGBA", image.size, (0, 0, 0, 255))
    shadow_mask = mask.filter(ImageFilter.GaussianBlur(size * 0.025))
    shadow.putalpha(shadow_mask.point(lambda value: value * shadow_alpha // 255))
    image.alpha_composite(shadow, (0, round(size * 0.018)))

    page = vertical_gradient(size, top, bottom)
    page.putalpha(masked_alpha(page.getchannel("A"), mask))
    image.alpha_composite(page)

    edge = Image.new("RGBA", image.size, (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle(
        box,
        radius=radius,
        outline=outline,
        width=max(1, round(size * 0.006)),
    )
    image.alpha_composite(edge)

    highlight = Image.new("RGBA", image.size, (0, 0, 0, 0))
    x0, y0, x1, _ = box
    ImageDraw.Draw(highlight).rounded_rectangle(
        [x0 + size * 0.015, y0 + size * 0.012, x1 - size * 0.015, y0 + size * 0.028],
        radius=size * 0.01,
        fill=(255, 255, 255, 90),
    )
    highlight.putalpha(masked_alpha(highlight.getchannel("A"), mask))
    image.alpha_composite(highlight)


def make_icon(size):
    scale = 4 if size < 256 else 2
    work = size * scale
    image = Image.new("RGBA", (work, work), (0, 0, 0, 0))
    tile_mask = rounded_mask(work, [0, 0, work - 1, work - 1], work * 0.225)

    background = vertical_gradient(work, (13, 42, 74, 255), (3, 20, 42, 255))
    glow = Image.new("RGBA", (work, work), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse(
        [work * 0.12, work * 0.05, work * 0.88, work * 0.80],
        fill=(34, 100, 150, 48),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(work * 0.12))
    background = Image.alpha_composite(background, glow)
    background.putalpha(tile_mask)
    image.alpha_composite(background)

    back_box = [work * 0.20, work * 0.23, work * 0.60, work * 0.67]
    front_box = [work * 0.40, work * 0.33, work * 0.80, work * 0.77]
    page_radius = work * 0.075

    glass_page(
        image,
        back_box,
        page_radius,
        (215, 237, 250, 150),
        (106, 150, 183, 112),
        (224, 246, 255, 185),
        78,
    )

    seam_box = [
        front_box[0] - work * 0.010,
        front_box[1] + work * 0.055,
        front_box[0] + work * 0.020,
        front_box[3] - work * 0.055,
    ]
    seam = vertical_gradient(work, (42, 226, 238, 210), (113, 87, 246, 165))
    seam.putalpha(rounded_mask(work, seam_box, work * 0.018))
    image.alpha_composite(seam)

    glass_page(
        image,
        front_box,
        page_radius,
        (252, 255, 255, 238),
        (210, 224, 235, 224),
        (255, 255, 255, 215),
        105,
    )

    image.putalpha(masked_alpha(image.getchannel("A"), tile_mask))
    if scale > 1:
        image = image.resize((size, size), Image.Resampling.LANCZOS)
    return image


os.makedirs(ICON_DIR, exist_ok=True)
for filename, pixels in SIZES:
    make_icon(pixels).save(os.path.join(ICON_DIR, filename), "PNG")
    print(f"  {filename} ({pixels}x{pixels})")
print("Done.")
