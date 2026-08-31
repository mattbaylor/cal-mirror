#!/usr/bin/env python3
"""Ask App Store Connect whether a version is live, and stamp the changelog.

Exits 0 and prints nothing actionable when there is nothing to do, so the
scheduled workflow is quiet until the day it matters.
"""
import base64, json, os, re, sys, time, urllib.request, urllib.error
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import ec, utils as asym_utils

APP = "6787358036"
PAGE = "docs/changelog.html"
HOME = "docs/index.html"
LIVE = {"READY_FOR_DISTRIBUTION", "READY_FOR_SALE"}

# Which version to watch is read off the changelog itself — whichever entry
# carries the "In review" pill. Hardcoding it here meant the workflow's commit
# messages still said 1.3.0 while 1.4.0 was the one in review, and nobody
# noticed because the watcher is a no-op almost every time it runs.
PILL = re.compile(r'<h2>([0-9][0-9.]*)</h2>\s*<span class="tag">In review</span>')

# Copy that is only true while a version is unreleased is wrapped in these, so
# it can be removed without hand-editing prose on the day review clears.
UNRELEASED = re.compile(r'[ \t]*<!--UNRELEASED-->.*?<!--/UNRELEASED-->[ \t]*\n?', re.S)

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
    pending = PILL.findall(src)
    if not pending:
        print(f"{PAGE} carries no 'In review' pill — nothing to do.")
        return 0
    # Two versions can be waiting at once — 1.4.1 submitted while 1.4.0 is still
    # in review. Take the lowest, which is the one that clears first; the next
    # scheduled run picks up the one after it.
    version = min(pending, key=lambda v: tuple(int(x) for x in v.split(".")))
    if len(pending) > 1:
        print("pending: %s — taking %s" % (", ".join(pending), version))
    print(f"watching {version}")

    tok = token()
    states = {}
    for v in get(f"/v1/apps/{APP}/appStoreVersions?limit=20", tok).get("data", []):
        a = v["attributes"]
        if a.get("versionString") == version:
            states[a.get("platform")] = a.get("appVersionState") or a.get("appStoreState")
    if not states:
        print(f"No {version} versions found.")
        return 0

    print("state:", ", ".join(f"{k}={v}" for k, v in sorted(states.items())))
    if not all(s in LIVE for s in states.values()):
        print("Not live on every platform yet.")
        return 0

    # Approved everywhere — swap the pill for today's date.
    today = time.strftime("%-d %B %Y")
    # Anchored to this version's heading: rewriting the first pill in document
    # order would stamp the newest entry, not the one that actually shipped.
    stamp = re.compile(r'(<h2>' + re.escape(version) + r'</h2>)\s*'
                       r'<span class="tag">In review</span><span class="date">submitted [^<]*</span>')
    out, n = stamp.subn(r'\1<span class="date">' + today + '</span>', src, count=1)
    if n != 1:
        print("::error::could not rewrite the pill — markup changed?")
        return 1
    # Only clear the "not on the App Store yet" copy once nothing is still
    # waiting — with another version in review those notes are still true.
    still_pending = PILL.findall(out)
    if still_pending:
        print("still in review, keeping the unreleased notes: %s" % ", ".join(still_pending))
        open(PAGE, "w").write(out)
    else:
        open(PAGE, "w").write(UNRELEASED.sub("", out))
        home = open(HOME).read()
        stripped = UNRELEASED.sub("", home)
        if stripped != home:
            open(HOME, "w").write(stripped)
            print(f"removed unreleased notes from {HOME}")

    print(f"stamped {version} as released on {today}")
    with open(os.environ["GITHUB_OUTPUT"], "a") as fh:
        fh.write("released=true\n")
        fh.write(f"date={today}\n")
        fh.write(f"version={version}\n")
    return 0

if __name__ == "__main__":
    sys.exit(main())
