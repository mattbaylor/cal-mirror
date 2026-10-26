#!/usr/bin/env python3
"""Build the App Store creative assets (iOS 27 / iPadOS 27 and later).

    ../creative/header-{en,de}.png   3840 x 1646   product page header (21:9)
    ../creative/search-{en,de}.png   3840 x 2560   search results (3:2, the maximum)

Calendar Mirror only: no AskWhen.me, no prices, no URLs (Apple's asset
guidance excludes pricing and website URLs, and AskWhen.me's pricing is about
to change). One image per language serves both appearances: App Store Connect
has no light/dark slot for these, so each sits on the same deep-blue gradient
as the store screenshots, which holds against a white page and a black one.

Neither image carries the app icon: the store draws the icon, name and Get
button right beside both placements, and the room is worth more as type size.

Header: the line centred, because the 21:9 frame may be cropped at its sides
on narrower devices ("keep your focal point in the centre"); the two calendar
cards either side are the idea drawn out — events on the left, the same hours
as busy blocks on the right — and can lose their outer edges without losing
the point. On an iPhone the header is about 393 pt wide, a tenth of the
canvas, so 240 px type reads at about 24 pt.

Search: the line on the left and the real list screen on the right. A search
row is about 361 pt wide, so the canvas is shown at under a tenth there too.
The app is English-only, so the capture is the same in both languages; only
the words around it change.

Copy lines are broken by hand ("|") rather than wrapped, so each language
breaks where it reads best.
"""
import os
from PIL import Image, ImageDraw, ImageFilter

from genstore import G_DEEP, font, gradient, rounded

HERE = os.path.dirname(os.path.abspath(__file__))
SHOTS = os.path.join(HERE, os.pardir, "sources")
OUT = os.path.join(HERE, os.pardir, "creative")

HEADER = (3840, 1646)
SEARCH = (3840, 2560)

W = (255, 255, 255, 255)
SUB = (255, 255, 255, 225)
INK = (6, 18, 31, 255)
GREY = (6, 18, 31, 150)
BLUE = (0x3A, 0xA0, 0xFF, 255)
TEAL = (0x24, 0xC2, 0xB0, 255)
BUSY = (0x8E, 0x9A, 0xAE, 255)

COPY = {
    "en": dict(
        header=("Your calendars,|mirrored.", "On your device.|No account, no server."),
        search=("Copy one|calendar into|another.", "Full details or just busy.|No server."),
        src="Work", dst="Personal", busy="Busy",
        events=[("9 AM", "Planning"), ("12:30 PM", "Team lunch"), ("3 PM", "Client call")],
    ),
    "de": dict(
        header=("Deine Kalender,|gespiegelt.", "Auf deinem Gerät.|Kein Konto, kein Server."),
        search=("Kopiere einen|Kalender in|einen anderen.", "Alle Details oder nur belegt.|Kein Server."),
        src="Arbeit", dst="Privat", busy="Belegt",
        events=[("9:00", "Planung"), ("12:30", "Teamessen"), ("15:00", "Kundentermin")],
    ),
}


def lines(base, text, fnt, x, y, fill, spacing, centre_w=None):
    """Draw the "|"-separated lines; centred in centre_w if given. Returns y below."""
    d = ImageDraw.Draw(base)
    lh = int(fnt.size * spacing)
    for i, ln in enumerate(text.split("|")):
        lx = x if centre_w is None else x + (centre_w - d.textlength(ln, font=fnt)) / 2
        d.text((lx, y + i * lh), ln, font=fnt, fill=fill)
    return y + len(text.split("|")) * lh


def widest(base, text, fnt):
    d = ImageDraw.Draw(base)
    return max(d.textlength(ln, font=fnt) for ln in text.split("|"))


def shadow(base, box, radius, blur=48, alpha=110, dy=18):
    sh = Image.new("RGBA", base.size, (0, 0, 0, 0))
    x0, y0, x1, y1 = box
    ImageDraw.Draw(sh).rounded_rectangle([x0, y0 + dy, x1, y1 + dy], radius=radius, fill=(0, 0, 0, alpha))
    base.alpha_composite(sh.filter(ImageFilter.GaussianBlur(blur)))


CARD = dict(pad=64, head=150, row=196, gap=34)


def card_height(n):
    return 2 * CARD["pad"] + CARD["head"] + n * CARD["row"] - CARD["gap"]


def calendar_card(base, x, y, w, title, events, busy=None, accent=BLUE):
    """A calendar drawn as a card: its name, then one block per event. With
    `busy`, every block reads that word instead of its title — the mirror."""
    pad, head, row, gap = CARD["pad"], CARD["head"], CARD["row"], CARD["gap"]
    h = card_height(len(events))
    r = 64
    shadow(base, (x, y, x + w, y + h), r)
    d = ImageDraw.Draw(base)
    d.rounded_rectangle([x, y, x + w, y + h], radius=r, fill=W)
    tf, timef, ef = font(84, "Bold"), font(48, "Medium"), font(62, "Semibold")
    dot = 34
    d.ellipse([x + pad, y + pad + 26, x + pad + dot, y + pad + 26 + dot], fill=accent)
    d.text((x + pad + dot + 28, y + pad - 6), title, font=tf, fill=INK)
    bar = BUSY if busy else accent
    # A tint of the bar on white, mixed here: ImageDraw writes alpha, it does not blend.
    tint = tuple(int(255 + (bar[i] - 255) * 0.2) for i in range(3)) + (255,)
    ey = y + pad + head
    for when, what in events:
        bh = row - gap
        d.rounded_rectangle([x + pad, ey, x + w - pad, ey + bh], radius=24, fill=tint)
        d.rounded_rectangle([x + pad, ey, x + pad + 14, ey + bh], radius=7, fill=bar)
        d.text((x + pad + 50, ey + (bh - 62 * 1.2) / 2), busy or what, font=ef, fill=INK)
        tw = d.textlength(when, font=timef)
        d.text((x + w - pad - 40 - tw, ey + (bh - 48 * 1.2) / 2), when, font=timef, fill=GREY)
        ey += row
    return h


def header(lang):
    c = COPY[lang]
    base = gradient(HEADER, *G_DEEP).convert("RGBA")
    Wd, Hd = HEADER
    head, sub = c["header"]
    hf, sf = font(240, "Bold"), font(124, "Medium")
    hsp, ssp, sgap = 1.06, 1.22, 60
    block = len(head.split("|")) * int(hf.size * hsp) + sgap + len(sub.split("|")) * int(sf.size * ssp)
    top = (Hd - block) // 2
    colw = int(max(widest(base, head, hf), widest(base, sub, sf)))
    cx = (Wd - colw) // 2
    y = lines(base, head, hf, cx, top, W, hsp, centre_w=colw)
    lines(base, sub, sf, cx, y + sgap, SUB, ssp, centre_w=colw)
    # The cards either side of the column, vertically centred on the canvas.
    cw, margin = 800, 120
    assert margin + cw + 120 < cx, "%s: header line runs into the cards" % lang
    cy = (Hd - card_height(len(c["events"]))) // 2
    calendar_card(base, margin, cy, cw, c["src"], c["events"], accent=BLUE)
    calendar_card(base, Wd - margin - cw, cy, cw, c["dst"], c["events"], busy=c["busy"], accent=TEAL)
    return base


def search(lang):
    c = COPY[lang]
    base = gradient(SEARCH, *G_DEEP).convert("RGBA")
    Wd, Hd = SEARCH
    head, sub = c["search"]
    # The list screen, from "Sync now" down to the end of its last mirror row.
    shot = Image.open(os.path.join(SHOTS, "ios-list-light.png")).convert("RGBA").crop((0, 150, 1206, 1790))
    sh_h = Hd - 2 * 300
    sc = sh_h / shot.height
    shot = shot.resize((int(shot.width * sc), sh_h), Image.LANCZOS)
    r = 90
    sx = Wd - 240 - shot.width
    sy = (Hd - sh_h) // 2
    shadow(base, (sx, sy, sx + shot.width, sy + sh_h), r, blur=60, alpha=120, dy=22)
    base.alpha_composite(rounded(shot, r), (sx, sy))
    # Text column: everything left of the capture.
    mx = 220
    hf, sf = font(270, "Bold"), font(146, "Medium")
    hsp, ssp, sgap = 1.04, 1.2, 100
    colw = max(widest(base, head, hf), widest(base, sub, sf))
    assert mx + colw + 120 < sx, "%s: search line runs into the capture" % lang
    block = len(head.split("|")) * int(hf.size * hsp) + sgap + len(sub.split("|")) * int(sf.size * ssp)
    y = (Hd - block) // 2
    y = lines(base, head, hf, mx, y, W, hsp)
    lines(base, sub, sf, mx, y + sgap, SUB, ssp)
    return base


def save(img, name):
    os.makedirs(OUT, exist_ok=True)
    out = os.path.join(OUT, name)
    # RGB: App Store Connect refuses an alpha channel on these.
    img.convert("RGB").save(out, "PNG", optimize=True)
    print(out, img.size)


if __name__ == "__main__":
    for lang in COPY:
        save(header(lang), "header-%s.png" % lang)
        save(search(lang), "search-%s.png" % lang)
