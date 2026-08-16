#!/usr/bin/env python3
"""Kopy icon: centered 6-spoke wheel, blue right / green left, crisp."""
import math, os
from PIL import Image, ImageDraw, ImageFilter

ICON_DIR = "kopy/Assets.xcassets/AppIcon.appiconset"
SIZES = [
    ("icon_16x16.png",16),("icon_16x16@2x.png",32),
    ("icon_32x32.png",32),("icon_32x32@2x.png",64),
    ("icon_128x128.png",128),("icon_128x128@2x.png",256),
    ("icon_256x256.png",256),("icon_256x256@2x.png",512),
    ("icon_512x512.png",512),("icon_512x512@2x.png",1024),
]

def lerp(a,b,t): return a+(b-a)*t

def make_icon(sz):
    cx = cy = sz/2
    corner  = sz * 0.225
    spoke_r = sz * 0.355    # hub-centre to dot-centre
    dot_r   = sz * 0.048    # dot radius (no giant glow)
    hub_r   = sz * 0.052
    lw      = max(1, int(sz * 0.018))

    img = Image.new("RGBA",(sz,sz),(0,0,0,0))

    # ── Background ────────────────────────────────────────────────────────────
    bg = Image.new("RGBA",(sz,sz),(0,0,0,0))
    bd = ImageDraw.Draw(bg)
    bd.rounded_rectangle([0,0,sz-1,sz-1], radius=corner, fill=(12,14,24,255))
    # soft radial glow
    for i in range(36,0,-1):
        t = i/36; r = sz*0.48*t
        bd.ellipse([cx-r,cy-r,cx+r,cy+r], fill=(22,42,100,int(28*t)))
    img = Image.alpha_composite(img, bg)
    draw = ImageDraw.Draw(img)

    # ── 6 evenly-spaced spokes ────────────────────────────────────────────────
    # right side (0°, ±48°) → blue; left side (180°, 180°±48°) → green
    base_angles = [0, 48, -48, 180, 180+48, 180-48]
    is_right    = [True, True, True, False, False, False]
    blue  = (70, 140, 255)
    green = (50, 210, 120)

    for angle_deg, right in zip(base_angles, is_right):
        angle = math.radians(angle_deg)
        ex = cx + spoke_r * math.cos(angle)
        ey = cy + spoke_r * math.sin(angle)
        cr, cg, cb = blue if right else green

        # spoke line — fade from hub edge to dot
        segs = 20
        for s in range(segs):
            t0 = s/segs; t1 = (s+1)/segs
            x0 = cx + lerp(hub_r*1.1, spoke_r-dot_r*1.05, t0)*math.cos(angle)
            y0 = cy + lerp(hub_r*1.1, spoke_r-dot_r*1.05, t0)*math.sin(angle)
            x1 = cx + lerp(hub_r*1.1, spoke_r-dot_r*1.05, t1)*math.cos(angle)
            y1 = cy + lerp(hub_r*1.1, spoke_r-dot_r*1.05, t1)*math.sin(angle)
            a  = int(lerp(180, 40, t0))
            draw.line([x0,y0,x1,y1], fill=(cr,cg,cb,a), width=lw)

        # dot — crisp, no huge glow rings
        # small soft halo (1 step only)
        hr = dot_r + sz*0.014
        draw.ellipse([ex-hr,ey-hr,ex+hr,ey+hr], fill=(cr,cg,cb,30))
        # body gradient
        for s in range(10,0,-1):
            f = s/10; r2 = dot_r*f
            rv = int(lerp(cr,255,f)); gv = int(lerp(cg,255,f)); bv = int(lerp(cb,255,f))
            draw.ellipse([ex-r2,ey-r2,ex+r2,ey+r2], fill=(rv,gv,bv,int(lerp(140,245,f))))
        # rim
        draw.ellipse([ex-dot_r,ey-dot_r,ex+dot_r,ey+dot_r],
                     outline=(210,230,255,110), width=max(1,int(sz*0.006)))

    # ── Hub ───────────────────────────────────────────────────────────────────
    hr2 = hub_r + sz*0.018
    draw.ellipse([cx-hr2,cy-hr2,cx+hr2,cy+hr2], fill=(120,175,255,35))
    for s in range(12,0,-1):
        f = s/12; r2 = hub_r*f
        lv = int(lerp(100,255,f))
        draw.ellipse([cx-r2,cy-r2,cx+r2,cy+r2], fill=(lv,lv,255,int(220*f+35)))
    draw.ellipse([cx-hub_r,cy-hub_r,cx+hub_r,cy+hub_r],
                 outline=(210,232,255,150), width=max(1,int(sz*0.008)))

    # ── Edge vignette ─────────────────────────────────────────────────────────
    vig = Image.new("RGBA",(sz,sz),(0,0,0,0))
    ImageDraw.Draw(vig).rounded_rectangle([0,0,sz-1,sz-1],radius=corner,fill=(0,0,0,48))
    clear = Image.new("RGBA",(sz,sz),(0,0,0,0))
    ImageDraw.Draw(clear).ellipse([cx-sz*0.40,cy-sz*0.40,cx+sz*0.40,cy+sz*0.40],fill=(0,0,0,48))
    clear = clear.filter(ImageFilter.GaussianBlur(sz*0.13))
    vig.paste((0,0,0,0), mask=clear.split()[3])
    img = Image.alpha_composite(img, vig)

    # ── Clip ──────────────────────────────────────────────────────────────────
    mask = Image.new("L",(sz,sz),0)
    ImageDraw.Draw(mask).rounded_rectangle([0,0,sz-1,sz-1],radius=corner,fill=255)
    img.putalpha(mask)
    return img

os.makedirs(ICON_DIR, exist_ok=True)
for filename, px in SIZES:
    make_icon(px).save(os.path.join(ICON_DIR, filename), "PNG")
    print(f"  {filename}  ({px}x{px})")
print("Done.")
