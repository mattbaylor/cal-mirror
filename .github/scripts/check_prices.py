#!/usr/bin/env python3
"""Re-check the App Store prices the comparison pages assert.

Thirteen pages quote competitors' prices and date them. A stale price is the one
thing those pages cannot survive — it turns an honest comparison into a false
claim, quietly, without anyone touching the file.

Six of the thirteen are App Store apps, so their price is a free lookup. This
compares what Apple reports today against what `prices.json` recorded, and
fails loudly on drift. It is read-only: it never edits a page, because the right
correction is a judgement (a price change may want new wording, not just a new
number).

    python3 .github/scripts/check_prices.py
"""
import json, os, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST = os.path.join(HERE, "prices.json")
LOOKUP = "https://itunes.apple.com/lookup?id={}&country=us"


def fetch(track_id):
    with urllib.request.urlopen(LOOKUP.format(track_id), timeout=30) as r:
        results = json.load(r).get("results") or []
    if not results:
        return None
    a = results[0]
    return {"name": a.get("trackName"),
            "price": a.get("formattedPrice"),
            "version": a.get("version")}


def main():
    manifest = json.load(open(MANIFEST))
    checked = manifest["checked"]
    drift, gone = [], []

    print(f"Prices recorded {checked}\n")
    for app in manifest["apps"]:
        live = fetch(app["id"])
        if live is None:
            gone.append(app)
            print(f"  {app['page']:22} {app['name']:28} DELISTED? no result for {app['id']}")
            continue
        same = live["price"] == app["price"]
        print(f"  {app['page']:22} {live['name'][:28]:28} "
              f"{app['price']:>10} -> {live['price']:>10} "
              f"{'ok' if same else 'CHANGED'}")
        if not same:
            app["live"] = live["price"]
            drift.append(app)

    print()
    if not drift and not gone:
        print(f"No drift. {len(manifest['apps'])} App Store prices still match.")
        return 0

    for a in drift:
        print(f"::warning::{a['name']} is now {a['live']}, page says {a['price']} "
              f"(docs/vs/{a['page']})")
    for a in gone:
        print(f"::warning::{a['name']} returned no App Store result — delisted? "
              f"(docs/vs/{a['page']})")
    print("\nUpdate the page wording and then the price in "
          ".github/scripts/prices.json, and move the checked date.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
