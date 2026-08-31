#!/usr/bin/env python3
"""Report what App Store Connect actually holds for a version.

Read-only. Nothing here creates, changes or submits anything — it exists so a
release can be checked before it is touched, rather than after.

    CM_VERSION=1.4.1 python3 .github/scripts/asc_status.py
"""
import base64, json, os, sys, time, urllib.request, urllib.error
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import ec, utils as asym_utils

APP = "6787358036"
WANT = os.environ.get("CM_VERSION", "1.4.1")
API = "https://api.appstoreconnect.apple.com"


def token():
    key_id = os.environ["ASC_KEY_ID"]
    issuer = os.environ["ASC_ISSUER_ID"]
    pem = base64.b64decode(os.environ["ASC_KEY_P8"])
    priv = serialization.load_pem_private_key(pem, password=None)
    b64 = lambda d: base64.urlsafe_b64encode(d).rstrip(b"=")
    hdr = b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"},
                         separators=(",", ":")).encode())
    now = int(time.time())
    pay = b64(json.dumps({"iss": issuer, "iat": now, "exp": now + 600,
                          "aud": "appstoreconnect-v1"}, separators=(",", ":")).encode())
    r, s = asym_utils.decode_dss_signature(priv.sign(hdr + b"." + pay, ec.ECDSA(hashes.SHA256())))
    return (hdr + b"." + pay + b"." + b64(r.to_bytes(32, "big") + s.to_bytes(32, "big"))).decode()


TOK = None


def get(path):
    req = urllib.request.Request(API + path, headers={"Authorization": "Bearer " + TOK})
    try:
        return json.load(urllib.request.urlopen(req))
    except urllib.error.HTTPError as e:
        body = e.read().decode()[:400]
        print(f"    ! {e.code} on {path}: {body}")
        return {"data": []}


def main():
    global TOK
    TOK = token()

    print(f"App {APP} — looking for {WANT}\n")

    # Every version on the record, so a missing one is obvious rather than implied.
    print("VERSIONS")
    versions = get(f"/v1/apps/{APP}/appStoreVersions?limit=30").get("data", [])
    mine = []
    for v in versions:
        a = v["attributes"]
        state = a.get("appVersionState") or a.get("appStoreState")
        mark = "  <-" if a.get("versionString") == WANT else ""
        print(f"  {a.get('versionString'):8} {a.get('platform'):8} {state}{mark}")
        if a.get("versionString") == WANT:
            mine.append(v)
    if not mine:
        print(f"\n  {WANT} does not exist yet on any platform.")

    # Builds Apple has accepted, so we can see whether 10 is processed and usable.
    print("\nBUILDS (most recent)")
    builds = get(f"/v1/builds?filter[app]={APP}&limit=8"
                 f"&fields[builds]=version,processingState,uploadedDate,expired").get("data", [])
    for b in builds:
        a = b["attributes"]
        print(f"  build {a.get('version'):4} {a.get('processingState'):12} "
              f"expired={a.get('expired')} {a.get('uploadedDate')}")

    # Name and subtitle live on appInfoLocalizations, NOT on the version — this
    # is the pair the 1.4.1 release exists to change.
    print("\nNAME / SUBTITLE (appInfo)")
    for info in get(f"/v1/apps/{APP}/appInfos?limit=10").get("data", []):
        st = info["attributes"].get("appStoreState") or info["attributes"].get("state")
        locs = get(f"/v1/appInfos/{info['id']}/appInfoLocalizations?limit=10").get("data", [])
        for l in locs:
            a = l["attributes"]
            if a.get("locale") != "en-US":
                continue
            print(f"  [{st}] name={a.get('name')!r} subtitle={a.get('subtitle')!r}")

    # Per-version copy and, crucially, whether any screenshots are attached.
    for v in mine:
        plat = v["attributes"].get("platform")
        print(f"\n{plat} {WANT} — attached build")
        bl = get(f"/v1/appStoreVersions/{v['id']}/build?fields[builds]=version").get("data")
        print(f"  {('build ' + bl['attributes']['version']) if bl else 'none attached'}")

        print(f"{plat} {WANT} — localization")
        for l in get(f"/v1/appStoreVersions/{v['id']}/appStoreVersionLocalizations?limit=10").get("data", []):
            a = l["attributes"]
            if a.get("locale") != "en-US":
                continue
            print(f"  description {len(a.get('description') or '')} chars, "
                  f"keywords {a.get('keywords')!r}, whatsNew {len(a.get('whatsNew') or '')} chars")

            print(f"{plat} {WANT} — screenshots")
            sets = get(f"/v1/appStoreVersionLocalizations/{l['id']}/appScreenshotSets?limit=20").get("data", [])
            if not sets:
                print("  NONE — no screenshot sets on this version")
            for st in sets:
                dt = st["attributes"].get("screenshotDisplayType")
                shots = get(f"/v1/appScreenshotSets/{st['id']}/appScreenshots?limit=20").get("data", [])
                done = sum(1 for s in shots
                           if (s["attributes"].get("assetDeliveryState") or {}).get("state") == "COMPLETE")
                print(f"  {dt:28} {len(shots)} image(s), {done} complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
