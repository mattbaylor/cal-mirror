#!/usr/bin/env python3
"""Ask App Store Connect whether a version is live, and stamp the changelog.

Exits 0 and prints nothing actionable when there is nothing to do, so the
scheduled workflow is quiet until the day it matters.
"""
import base64, json, os, re, sys, time, urllib.request, urllib.error
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import ec, utils as asym_utils

APP = "6787358036"
VERSION = os.environ.get("CM_WATCH_VERSION", "1.3.0")
PAGE = "docs/changelog.html"
LIVE = {"READY_FOR_DISTRIBUTION", "READY_FOR_SALE"}

def token():
    key_id = os.environ["ASC_KEY_ID"]
    issuer = os.environ["ASC_ISSUER_ID"]
    pem = base64.b64decode(os.environ["ASC_KEY_P8"])
    priv = serialization.load_pem_private_key(pem, password=None)
    b64 = lambda d: base64.urlsafe_b64encode(d).rstrip(b"=")
    hdr = b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}, separators=(",", ":")).encode())
    now = int(time.time())
    pay = b64(json.dumps({"iss": issuer, "iat": now, "exp": now + 600,
                          "aud": "appstoreconnect-v1"}, separators=(",", ":")).encode())
    r, s = asym_utils.decode_dss_signature(priv.sign(hdr + b"." + pay, ec.ECDSA(hashes.SHA256())))
    return (hdr + b"." + pay + b"." + b64(r.to_bytes(32, "big") + s.to_bytes(32, "big"))).decode()

def get(path, tok):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path,
                                 headers={"Authorization": "Bearer " + tok})
    return json.load(urllib.request.urlopen(req))

def main():
    src = open(PAGE).read()
    if "In review" not in src:
        print(f"{PAGE} carries no 'In review' pill — nothing to do.")
        return 0

    tok = token()
    states = {}
    for v in get(f"/v1/apps/{APP}/appStoreVersions?limit=20", tok).get("data", []):
        a = v["attributes"]
        if a.get("versionString") == VERSION:
            states[a.get("platform")] = a.get("appVersionState") or a.get("appStoreState")
    if not states:
        print(f"No {VERSION} versions found.")
        return 0

    print("state:", ", ".join(f"{k}={v}" for k, v in sorted(states.items())))
    if not all(s in LIVE for s in states.values()):
        print("Not live on every platform yet.")
        return 0

    # Approved everywhere — swap the pill for today's date.
    today = time.strftime("%-d %B %Y")
    out, n = re.subn(r'<span class="tag">In review</span><span class="date">submitted [^<]*</span>',
                     f'<span class="date">{today}</span>', src, count=1)
    if n != 1:
        print("::error::could not rewrite the pill — markup changed?")
        return 1
    open(PAGE, "w").write(out)
    print(f"stamped {VERSION} as released on {today}")
    with open(os.environ["GITHUB_OUTPUT"], "a") as fh:
        fh.write("released=true\n")
        fh.write(f"date={today}\n")
    return 0

if __name__ == "__main__":
    sys.exit(main())
