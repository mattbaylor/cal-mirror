#!/usr/bin/env python3
"""Build the two images for the 2.0 In-App Event ("Share When You're Free").

    ../event/card.png      1920 x 1080   event card (16:9)
    ../event/details.png   1080 x 1920   event details page (9:16)

The App Store lays the badge, event name and short description over the
lower part of both, so neither image carries copy of its own: the request
page a requester sees, on AskWhen.me's warm gradient, kept inside the area
that survives the overlay (top ~5-8% and bottom ~40% are at risk, plus a
6% side margin). Captures are the synthetic owner Dana Cho from site/img.
"""
import os
from PIL import Image

from genstore import G_WARM, gradient, paste_shot

HERE = os.path.dirname(os.path.abspath(__file__))
IMG = os.path.join(HERE, os.pardir, os.pardir, "site", "img")
OUT = os.path.join(HERE, os.pardir, "event")


def build(name, size, shot, crop, box_w, top):
    base = gradient(size, *G_WARM).convert("RGBA")
    bottom = paste_shot(base, os.path.join(IMG, shot), box_w, top, radius=28, crop=crop)
    safe = int(size[1] * 0.60)
    assert bottom <= safe, "%s: capture ends at %d, past the safe line at %d" % (name, bottom, safe)
    os.makedirs(OUT, exist_ok=True)
    out = os.path.join(OUT, name)
    base.convert("RGB").save(out, "PNG", optimize=True)
    print(out, size, "capture ends at", bottom, "of", safe)


if __name__ == "__main__":
    # Desktop request page: the heading, the "offer, not a reservation" note,
    # the four steps and the first day of times.
    build("card.png", (1920, 1080), "askwhen-desk-pick-light.png",
          crop=(200, 24, 900, 658), box_w=640, top=60)
    # Phone request page, down to the first row of times.
    build("details.png", (1080, 1920), "askwhen-req-pick-light.png",
          crop=(0, 0, 570, 1030), box_w=540, top=170)
