#!/usr/bin/env python3
"""Build App Store screenshots for cal-mirror 1.4.0.

Ten frames per device class, composited from the scrubbed captures in
./shots (every one taken from a throwaway config with invented calendar
names). Output sizes are the ones App Store Connect accepts:

    iPhone 6.5"   1242 x 2688
    iPad 13"      2064 x 2752
    Mac           1440 x 900

Mac frames are 1440x900 rather than 2880x1800 deliberately: the window
captures are 1x, so a larger canvas would only upscale them. Here they sit
close to pixel-native.
"""
import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
SHOTS = os.path.join(HERE, os.pardir, "sources")
OUT = os.path.join(HERE, os.pardir, "screenshots")
FONT = "/System/Library/Fonts/SFNS.ttf"

SIZES = {"iphone": (1242, 2688), "ipad": (2064, 2752), "mac": (1440, 900)}

# Brand gradients, rotated for variety across the ten frames.
G_TEAL = ((0x24, 0xC2, 0xB0), (0x3A, 0xA0, 0xFF))
G_BLUE = ((0x3A, 0xA0, 0xFF), (0x6B, 0x5B, 0xF5))
G_DEEP = ((0x12, 0x62, 0xD6), (0x1E, 0x2B, 0x6B))
G_DARK = ((0x0D, 0x14, 0x22), (0x1A, 0x2A, 0x44))
G_MINT = ((0x1FB, 0, 0)[0] and (0x17, 0xB8, 0x9E), (0x24, 0xC2, 0xB0))


def font(px, weight="Bold"):
    f = ImageFont.truetype(FONT, px)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass
    return f


def gradient(size, c1, c2):
    """Diagonal gradient, drawn small and upscaled — fast and smooth."""
    w, h = size
    small = Image.new("RGB", (64, 64))
    px = small.load()
    for y in range(64):
        for x in range(64):
            t = (x + y) / 126.0
            px[x, y] = tuple(int(c1[i] + (c2[i] - c1[i]) * t) for i in range(3))
    return small.resize((w, h), Image.BICUBIC)


def wrap(draw, text, fnt, max_w):
    out, line = [], ""
    for word in text.split():
        trial = (line + " " + word).strip()
        if draw.textlength(trial, font=fnt) <= max_w or not line:
            line = trial
        else:
            out.append(line)
            line = word
    if line:
        out.append(line)
    return out


def text_block(img, text, fnt, x, y, max_w, fill, spacing=1.18, align="left", shadow=False):
    d = ImageDraw.Draw(img)
    lines = wrap(d, text, fnt, max_w)
    lh = int(fnt.size * spacing)
    for i, ln in enumerate(lines):
        w = d.textlength(ln, font=fnt)
        lx = x if align == "left" else x + (max_w - w) / 2
        if shadow:
            sh = Image.new("RGBA", img.size, (0, 0, 0, 0))
            ImageDraw.Draw(sh).text((lx, y + i * lh), ln, font=fnt, fill=(0, 0, 0, 70))
            img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(6)))
        d.text((lx, y + i * lh), ln, font=fnt, fill=fill)
    return y + len(lines) * lh


def rounded(im, radius):
    im = im.convert("RGBA")
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, im.size[0] - 1, im.size[1] - 1],
                                           radius=radius, fill=255)
    im.putalpha(mask)
    return im


def paste_shot(base, path, box_w, top, radius=26, crop=None, shadow=48):
    """Scale a capture to box_w and paste centred at y=top, with a soft shadow.
    `crop` is a (l, t, r, b) box applied before scaling."""
    im = Image.open(path).convert("RGBA")
    if crop:
        im = im.crop(crop)
    sc = box_w / im.width
    im = im.resize((box_w, max(1, int(im.height * sc))), Image.LANCZOS)
    im = rounded(im, radius)
    x = (base.width - im.width) // 2
    if shadow:
        sh = Image.new("RGBA", base.size, (0, 0, 0, 0))
        ImageDraw.Draw(sh).rounded_rectangle(
            [x, top + 14, x + im.width, top + im.height + 14], radius=radius, fill=(0, 0, 0, 95))
        base.alpha_composite(sh.filter(ImageFilter.GaussianBlur(shadow)))
    base.alpha_composite(im, (x, top))
    return top + im.height


def bullets(img, items, fnt, x, y, max_w, fill, gap=1.9, dot=(255, 255, 255, 235)):
    d = ImageDraw.Draw(img)
    for it in items:
        r = int(fnt.size * 0.17)
        cy = y + int(fnt.size * 0.52)
        d.ellipse([x, cy - r, x + 2 * r, cy + r], fill=dot)
        ny = text_block(img, it, fnt, x + int(fnt.size * 0.85), y, max_w - int(fnt.size * 0.85), fill)
        y = ny + int(fnt.size * (gap - 1.18) * 0.5)
    return y


def icon(base, box, size_px, top):
    p = os.path.join(HERE, os.pardir, os.pardir, "assets", "AppIcon-ios-1024.png")
    if not os.path.exists(p):
        return top
    im = Image.open(p).convert("RGBA").resize((size_px, size_px), Image.LANCZOS)
    im = rounded(im, int(size_px * 0.22))
    x = (base.width - size_px) // 2
    sh = Image.new("RGBA", base.size, (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle([x, top + 12, x + size_px, top + size_px + 12],
                                         radius=int(size_px * 0.22), fill=(0, 0, 0, 90))
    base.alpha_composite(sh.filter(ImageFilter.GaussianBlur(34)))
    base.alpha_composite(im, (x, top))
    return top + size_px


# --------------------------------------------------------------- frame specs
# kind: "shot"  -> headline + subtitle + capture
#       "hero"  -> app icon + headline + subtitle
#       "list"  -> headline + subtitle + bullet list
W = "#FFFFFF"
SUB = (255, 255, 255, 224)

FRAMES = [
    # 1
    dict(kind="hero", grad=G_TEAL,
         head="Keep a copy of one calendar inside another.",
         sub="One direction. Your original is never touched."),
    # 2
    dict(kind="shot", grad=G_BLUE,
         head="Every copy in one list.",
         sub="Grouped by the calendar they land in, with health and event counts.",
         shot=dict(iphone="ios-list-light.png", ipad="ipad-list.png", mac="mac-manage-light.png"),
         crop=dict(ipad=(0, 0, 2064, 1465))),
    # 3
    dict(kind="shot", grad=G_TEAL,
         head="Point it at two calendars.",
         sub="Pick the one to copy from and the one to copy into. That's the setup.",
         shot=dict(iphone="ios-detail-light.png", ipad="ipad-detail.png", mac="mac-manage-light.png"),
         crop=dict(iphone=(0, 0, 1206, 1240), ipad=(0, 0, 2064, 1235))),
    # 4
    dict(kind="shot", grad=G_DEEP,
         head="Copy everything, or almost nothing.",
         sub="Full copy, title and location only, or a plain block that reads “Busy”.",
         shot=dict(iphone="ios-detail-light.png", ipad="ipad-detail.png", mac="mac-projection-light.png"),
         crop=dict(iphone=(0, 1205, 1206, 1585), ipad=(0, 0, 2064, 1235))),
    # 5
    dict(kind="shot", grad=G_TEAL,
         head="Copy the meetings. Skip the noise.",
         sub="Skip declined, cancelled, all-day and free events — no tagging needed.",
         shot=dict(iphone="ios-detail-light.png", ipad="ipad-detail.png", mac="mac-selection-light.png"),
         crop=dict(iphone=(0, 1395, 1206, 1905), ipad=(0, 560, 2064, 1235)),
         mac_crop=(0, 0, 940, 880)),
    # 6
    dict(kind="list", grad=G_BLUE,
         head="Filter on what the events already say.",
         sub="Works on calendars you don't control — a subscribed work feed, a team calendar.",
         items=["Declined, unanswered or cancelled",
                "All-day events, and anything marked free",
                "Shorter than 15 minutes, or longer than 8 hours",
                "Titles containing “Lunch” or “Focus time”",
                "Only 8am–6pm, Monday to Friday"]),
    # 7
    dict(mac_swap=dict(kind="icons", grad=G_DEEP,
                       head="Five faces, one glance.",
                       sub="The menu-bar icon wears the expression that matches what is happening.",
                       icons=[("ok", "All good"), ("degraded", "Behind"), ("failing", "Broken"),
                              ("paused", "Paused"), ("unconfigured", "Nothing set up")]),
         kind="list", grad=G_DEEP,
         head="Or decide one event at a time.",
         sub="Type a tag into a source event's notes and that event gets its own rule.",
         items=["#nomirror — never copy this one",
                "#private — copy it as a busy block",
                "#public — copy it in full",
                "Point a whole mirror at a tag to copy only what you've marked"]),
    # 8
    dict(kind="list", grad=G_TEAL,
         head="Label it. Link it.",
         sub="Two things a copy can carry across.",
         items=["Put “[Work]” in front of every copied title",
                "It applies to hidden titles too — “[Work] Busy”",
                "Carry the meeting link into the copy's notes",
                "So a mirrored meeting is one you can actually join"]),
    # 9
    dict(kind="shot", grad=G_BLUE,
         head="Silent when it works. Loud when it stops.",
         sub="A healthy mirror writes nothing. If one breaks, a warning appears in the calendar itself.",
         shot=dict(iphone="ios-list-light.png", ipad="ipad-list.png", mac="mac-warning-light.png"),
         crop=dict(ipad=(0, 0, 2064, 1465))),
    # 10
    dict(kind="list", grad=G_DARK,
         head="No account. No server. Nothing leaves your device.",
         sub="It works through the calendars already set up on your device.",
         items=["Nothing to sign up for, no password to hand over",
                "No analytics, no tracking, no telemetry",
                "Open source, MIT licensed",
                "One purchase covers iPhone, iPad and Mac"]),
]

# Per-platform layout metrics: (head px, sub px, body px, margin, top pad, shot width)
METRICS = {
    "iphone": dict(head=108, sub=54, body=62, margin=96, top=150, shotw=1000, gap=46),
    "ipad":   dict(head=150, sub=74, body=80, margin=170, top=190, shotw=1620, gap=58),
    "mac":    dict(head=64,  sub=32, body=31, margin=70,  top=64,  shotw=880,  gap=26),
}


def build(platform, idx, spec):
    if platform == "mac" and spec.get("mac_swap"):
        spec = spec["mac_swap"]
    size = SIZES[platform]
    m = METRICS[platform]
    base = gradient(size, *spec["grad"]).convert("RGBA")

    y = m["top"]
    maxw = size[0] - 2 * m["margin"]

    if platform == "mac" and spec["kind"] == "shot":
        # Mac frames are landscape: headline on the left, window on the right.
        path = os.path.join(SHOTS, spec["shot"]["mac"])
        crop = spec.get("mac_crop")
        im = Image.open(path).convert("RGBA")
        if crop:
            im = im.crop(crop)
        boxw = int(size[0] * 0.54)
        sc = boxw / im.width
        im = im.resize((boxw, int(im.height * sc)), Image.LANCZOS)
        if im.height > size[1] - 120:
            im = im.crop((0, 0, im.width, size[1] - 120))
        im = rounded(im, 18)
        x = size[0] - im.width - 46
        top = (size[1] - im.height) // 2
        # Text column: everything left of the window, minus a gutter.
        colw = x - m["margin"] - 46
        hf, sf = font(54, "Bold"), font(30, "Regular")
        d0 = ImageDraw.Draw(base)
        hl = wrap(d0, spec["head"], hf, colw)
        sl = wrap(d0, spec["sub"], sf, colw)
        block_h = len(hl) * int(hf.size * 1.14) + 26 + len(sl) * int(sf.size * 1.3)
        ty = max(m["margin"], (size[1] - block_h) // 2)
        ty = text_block(base, spec["head"], hf, m["margin"], ty, colw, W, spacing=1.14)
        text_block(base, spec["sub"], sf, m["margin"], ty + 26, colw, SUB, spacing=1.3)
        sh = Image.new("RGBA", base.size, (0, 0, 0, 0))
        ImageDraw.Draw(sh).rounded_rectangle([x, top + 12, x + im.width, top + im.height + 12],
                                             radius=18, fill=(0, 0, 0, 105))
        base.alpha_composite(sh.filter(ImageFilter.GaussianBlur(40)))
        base.alpha_composite(im, (x, top))

    elif spec["kind"] == "hero":
        isz = int(size[0] * (0.30 if platform != "mac" else 0.17))
        hf, sf = font(m["head"], "Bold"), font(m["sub"], "Regular")
        d0 = ImageDraw.Draw(base)
        hl = wrap(d0, spec["head"], hf, maxw)
        sl = wrap(d0, spec["sub"], sf, maxw)
        block = (isz + int(size[1] * 0.045) + len(hl) * int(hf.size * 1.14)
                 + m["gap"] + len(sl) * int(sf.size * 1.3))
        y = icon(base, None, isz, max(m["margin"], (size[1] - block) // 2))
        y += int(size[1] * 0.045)
        y = text_block(base, spec["head"], font(m["head"], "Bold"), m["margin"], y, maxw, W,
                       spacing=1.14, align="center")
        text_block(base, spec["sub"], font(m["sub"], "Regular"), m["margin"], y + m["gap"],
                   maxw, SUB, spacing=1.3, align="center")

    elif spec["kind"] == "icons":
        hf, sf = font(54, "Bold"), font(30, "Regular")
        d0 = ImageDraw.Draw(base)
        _h = len(wrap(d0, spec["head"], hf, maxw)) * int(hf.size * 1.14)
        _s = len(wrap(d0, spec["sub"], sf, maxw)) * int(sf.size * 1.3)
        y = max(m["margin"], (size[1] - (_h + 22 + _s + 66 + 116 + 48)) // 2)
        y = text_block(base, spec["head"], hf, m["margin"], y, maxw, W, spacing=1.14, align="center")
        y = text_block(base, spec["sub"], sf, m["margin"], y + 22, maxw, SUB, spacing=1.3, align="center")
        n = len(spec["icons"])
        cell, gsz = int(maxw / n), 116
        y += 66
        lf = font(26, "Semibold")
        d = ImageDraw.Draw(base)
        for i, (name, label) in enumerate(spec["icons"]):
            gp = os.path.join(SHOTS, "icons", "menubar-%s.png" % name)
            g = Image.open(gp).convert("RGBA").resize((gsz, gsz), Image.LANCZOS)
            # Template glyphs are black; invert to white for the gradient.
            wg = Image.new("RGBA", g.size, (255, 255, 255, 0))
            wg.putalpha(g.split()[3])
            cx = m["margin"] + i * cell + cell // 2
            base.alpha_composite(wg, (cx - gsz // 2, y))
            tw = d.textlength(label, font=lf)
            d.text((cx - tw / 2, y + gsz + 22), label, font=lf, fill=SUB)

    elif spec["kind"] == "list":
        hf = font(m["head"], "Bold")
        sf = font(m["sub"], "Regular")
        bf = font(m["body"], "Medium")
        d0 = ImageDraw.Draw(base)
        gap2 = int(m["gap"] * (2.4 if platform != "mac" else 1.6))
        bh = 0
        for it in spec["items"]:
            bh += len(wrap(d0, it, bf, maxw - int(bf.size * 0.85))) * int(bf.size * 1.18)
            bh += int(bf.size * (1.9 - 1.18) * 0.5)
        block = (len(wrap(d0, spec["head"], hf, maxw)) * int(hf.size * 1.14) + m["gap"]
                 + len(wrap(d0, spec["sub"], sf, maxw)) * int(sf.size * 1.3) + gap2 + bh)
        y = max(m["top"], (size[1] - block) // 2)
        y = text_block(base, spec["head"], hf, m["margin"], y, maxw, W, spacing=1.14)
        y = text_block(base, spec["sub"], sf, m["margin"], y + m["gap"], maxw, SUB, spacing=1.3)
        y += gap2
        bullets(base, spec["items"], bf, m["margin"], y, maxw, W)

    else:  # portrait shot
        y = text_block(base, spec["head"], font(m["head"], "Bold"), m["margin"], y, maxw, W,
                       spacing=1.12, align="center")
        y = text_block(base, spec["sub"], font(m["sub"], "Regular"), m["margin"], y + m["gap"],
                       maxw, SUB, spacing=1.3, align="center")
        crop = (spec.get("crop") or {}).get(platform)
        paste_shot(base, os.path.join(SHOTS, spec["shot"][platform]), m["shotw"],
                   y + int(m["gap"] * 2.2), radius=30, crop=crop)

    d = os.path.join(OUT, platform)
    os.makedirs(d, exist_ok=True)
    out = os.path.join(d, "%02d.png" % (idx + 1))
    base.convert("RGB").save(out, "PNG", optimize=True)
    return out


if __name__ == "__main__":
    for platform in SIZES:
        for i, spec in enumerate(FRAMES):
            p = build(platform, i, spec)
        print(platform, "->", len(FRAMES), "frames", SIZES[platform])
