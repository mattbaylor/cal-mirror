#!/usr/bin/env python3
"""Bring an App Store Connect version in line with what is in this repo.

Creates the version if it is missing, sets the subtitle, pushes the description,
keywords, promotional text and release notes, attaches a build, and uploads any
screenshots that are not already there. Optionally submits for review.

Everything is idempotent and everything is checked before it is written: a field
that already matches is skipped and says so, so a second run is quiet and safe.

    CM_VERSION=1.4.1 CM_BUILD=10 python3 .github/scripts/asc_apply.py            # plan only
    CM_VERSION=1.4.1 CM_BUILD=10 CM_APPLY=1 python3 .github/scripts/asc_apply.py # write
    ... CM_APPLY=1 CM_SUBMIT=1 ...                                               # and submit
"""
import base64, hashlib, json, os, sys, time, urllib.request, urllib.error
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import ec, utils as asym_utils

APP = "6787358036"
API = "https://api.appstoreconnect.apple.com"
VERSION = os.environ.get("CM_VERSION", "1.4.1")
BUILD = os.environ.get("CM_BUILD", "10")
APPLY = os.environ.get("CM_APPLY") == "1"
SUBMIT = os.environ.get("CM_SUBMIT") == "1"
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "appstore")

# Which metadata folder and screenshot folder feed each platform, and the
# display type App Store Connect files those screenshots under.
PLATFORMS = {
    "IOS":    dict(meta="ios", shots=[("iphone", "APP_IPHONE_65"),
                                      ("ipad", "APP_IPAD_PRO_3GEN_129")]),
    "MAC_OS": dict(meta="mac", shots=[("mac", "APP_DESKTOP")]),
}

TOK = None
changes, problems = [], []


def token():
    pem = base64.b64decode(os.environ["ASC_KEY_P8"])
    priv = serialization.load_pem_private_key(pem, password=None)
    b64 = lambda d: base64.urlsafe_b64encode(d).rstrip(b"=")
    hdr = b64(json.dumps({"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
                         separators=(",", ":")).encode())
    now = int(time.time())
    pay = b64(json.dumps({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1200,
                          "aud": "appstoreconnect-v1"}, separators=(",", ":")).encode())
    r, s = asym_utils.decode_dss_signature(priv.sign(hdr + b"." + pay, ec.ECDSA(hashes.SHA256())))
    return (hdr + b"." + pay + b"." + b64(r.to_bytes(32, "big") + s.to_bytes(32, "big"))).decode()


def call(method, path, body=None, raw=None, headers=None):
    url = path if path.startswith("http") else API + path
    h = {"Authorization": "Bearer " + TOK}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    if raw is not None:
        data = raw
    h.update(headers or {})
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req) as r:
            txt = r.read()
            return json.loads(txt) if txt and txt[:1] in b"{[" else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode()[:600]
        problems.append(f"{method} {path} -> {e.code} {detail}")
        print(f"    ! {e.code} {method} {path}\n      {detail}")
        return None


def get(path):
    return call("GET", path) or {"data": []}


def read(platform, field):
    p = os.path.join(ROOT, "metadata", PLATFORMS[platform]["meta"], field + ".txt")
    return open(p).read().strip("\n") if os.path.exists(p) else None


def want(label, current, desired, doit):
    """Write only when it differs, and always say which happened."""
    if current == desired:
        print(f"    = {label} already correct")
        return
    print(f"    ~ {label}: {(current or '')[:40]!r} -> {desired[:40]!r}")
    changes.append(label)
    if APPLY:
        doit()


# --------------------------------------------------------------------- version
def ensure_version(platform):
    for v in get(f"/v1/apps/{APP}/appStoreVersions?limit=40").get("data", []):
        a = v["attributes"]
        if a.get("versionString") == VERSION and a.get("platform") == platform:
            state = a.get("appVersionState") or a.get("appStoreState")
            print(f"    = version exists ({state})")
            return v["id"]
    print(f"    + create {platform} {VERSION}")
    changes.append(f"create {platform} {VERSION}")
    if not APPLY:
        return None
    r = call("POST", "/v1/appStoreVersions", {"data": {
        "type": "appStoreVersions",
        "attributes": {"platform": platform, "versionString": VERSION},
        "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})
    return r["data"]["id"] if r else None


def ensure_localization(vid, platform):
    locs = get(f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations?limit=20").get("data", [])
    loc = next((l for l in locs if l["attributes"].get("locale") == "en-US"), None)
    fields = {"description": read(platform, "description"),
              "keywords": read(platform, "keywords"),
              "whatsNew": read(platform, "whats_new"),
              "promotionalText": read(platform, "promotional_text")}
    if loc is None:
        print("    + create en-US localization")
        changes.append("create en-US localization")
        if not APPLY:
            return None
        r = call("POST", "/v1/appStoreVersionLocalizations", {"data": {
            "type": "appStoreVersionLocalizations",
            "attributes": dict(locale="en-US", **fields),
            "relationships": {"appStoreVersion": {
                "data": {"type": "appStoreVersions", "id": vid}}}}})
        return r["data"]["id"] if r else None

    lid, cur = loc["id"], loc["attributes"]
    for k, v in fields.items():
        if v is None:
            continue
        want(k, cur.get(k), v,
             lambda k=k, v=v: call("PATCH", f"/v1/appStoreVersionLocalizations/{lid}",
                                   {"data": {"type": "appStoreVersionLocalizations",
                                             "id": lid, "attributes": {k: v}}}))
    return lid


def ensure_build(vid, platform):
    found = None
    r = get(f"/v1/builds?filter[app]={APP}&filter[version]={BUILD}"
            f"&include=preReleaseVersion&limit=20")
    incl = {i["id"]: i for i in r.get("included", [])}
    for b in r.get("data", []):
        pre = (b.get("relationships", {}).get("preReleaseVersion", {}).get("data") or {})
        p = incl.get(pre.get("id"), {}).get("attributes", {}).get("platform")
        if p == platform:
            found = b["id"]
            break
    if not found:
        print(f"    ! no build {BUILD} for {platform}")
        problems.append(f"no build {BUILD} for {platform}")
        return
    cur = get(f"/v1/appStoreVersions/{vid}/build?fields[builds]=version").get("data")
    if cur and cur.get("id") == found:
        print(f"    = build {BUILD} already attached")
        return
    print(f"    ~ attach build {BUILD}")
    changes.append(f"attach build {BUILD} ({platform})")
    if APPLY:
        call("PATCH", f"/v1/appStoreVersions/{vid}/relationships/build",
             {"data": {"type": "builds", "id": found}})


# -------------------------------------------------------------------- subtitle
def ensure_subtitle():
    """Name and subtitle live on the editable appInfo, not on the version."""
    subtitle, name = read("IOS", "subtitle"), read("IOS", "name")
    for info in get(f"/v1/apps/{APP}/appInfos?limit=10").get("data", []):
        state = info["attributes"].get("appStoreState") or info["attributes"].get("state")
        if state in ("READY_FOR_SALE", "REPLACED_WITH_NEW_INFO"):
            continue  # not editable
        for l in get(f"/v1/appInfos/{info['id']}/appInfoLocalizations?limit=20").get("data", []):
            if l["attributes"].get("locale") != "en-US":
                continue
            lid, cur = l["id"], l["attributes"]
            print(f"    editable appInfo [{state}]")
            for k, v in (("name", name), ("subtitle", subtitle)):
                if not v:
                    continue
                want(k, cur.get(k), v,
                     lambda k=k, v=v: call("PATCH", f"/v1/appInfoLocalizations/{lid}",
                                           {"data": {"type": "appInfoLocalizations",
                                                     "id": lid, "attributes": {k: v}}}))
            return
    print("    ! no editable appInfo found")
    problems.append("no editable appInfo")


# ----------------------------------------------------------------- screenshots
def ensure_screenshots(lid, folder, display):
    sets = get(f"/v1/appStoreVersionLocalizations/{lid}/appScreenshotSets?limit=20").get("data", [])
    st = next((s for s in sets if s["attributes"].get("screenshotDisplayType") == display), None)
    files = sorted(f for f in os.listdir(os.path.join(ROOT, "screenshots", folder))
                   if f.endswith(".png"))

    if st is not None:
        shots = get(f"/v1/appScreenshotSets/{st['id']}/appScreenshots?limit=30").get("data", [])
        done = [s for s in shots
                if (s["attributes"].get("assetDeliveryState") or {}).get("state") == "COMPLETE"]
        if len(done) >= len(files):
            print(f"    = {display}: {len(done)} already uploaded")
            return
        print(f"    ~ {display}: {len(done)}/{len(files)} complete — filling the rest")
    else:
        print(f"    + {display}: create set and upload {len(files)}")
    changes.append(f"{display}: upload screenshots")
    if not APPLY:
        return

    if st is None:
        r = call("POST", "/v1/appScreenshotSets", {"data": {
            "type": "appScreenshotSets",
            "attributes": {"screenshotDisplayType": display},
            "relationships": {"appStoreVersionLocalization": {
                "data": {"type": "appStoreVersionLocalizations", "id": lid}}}}})
        if not r:
            return
        st = r["data"]
        have = set()
    else:
        have = {s["attributes"].get("fileName") for s in
                get(f"/v1/appScreenshotSets/{st['id']}/appScreenshots?limit=30").get("data", [])}

    for fn in files:
        if fn in have:
            continue
        path = os.path.join(ROOT, "screenshots", folder, fn)
        blob = open(path, "rb").read()
        r = call("POST", "/v1/appScreenshots", {"data": {
            "type": "appScreenshots",
            "attributes": {"fileSize": len(blob), "fileName": fn},
            "relationships": {"appScreenshotSet": {
                "data": {"type": "appScreenshotSets", "id": st["id"]}}}}})
        if not r:
            return
        sid = r["data"]["id"]
        for op in r["data"]["attributes"].get("uploadOperations", []):
            hdrs = {h["name"]: h["value"] for h in (op.get("requestHeaders") or [])}
            chunk = blob[op["offset"]:op["offset"] + op["length"]]
            call(op.get("method", "PUT"), op["url"], raw=chunk, headers=hdrs)
        call("PATCH", f"/v1/appScreenshots/{sid}", {"data": {
            "type": "appScreenshots", "id": sid,
            "attributes": {"uploaded": True,
                           "sourceFileChecksum": hashlib.md5(blob).hexdigest()}}})
        print(f"      uploaded {folder}/{fn}")


# ------------------------------------------------------------------ submission
def submit(platform, vid):
    for rs in get(f"/v1/apps/{APP}/reviewSubmissions"
                  f"?filter[platform]={platform}&filter[state]=READY_FOR_REVIEW,WAITING_FOR_REVIEW,"
                  f"IN_REVIEW&limit=10").get("data", []):
        print(f"    = review submission already {rs['attributes'].get('state')}")
        return
    print(f"    ~ submit {platform} {VERSION} for review")
    changes.append(f"submit {platform} for review")
    if not APPLY:
        return
    r = call("POST", "/v1/reviewSubmissions", {"data": {
        "type": "reviewSubmissions", "attributes": {"platform": platform},
        "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})
    if not r:
        return
    rsid = r["data"]["id"]
    if not call("POST", "/v1/reviewSubmissionItems", {"data": {
            "type": "reviewSubmissionItems",
            "relationships": {
                "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": rsid}},
                "appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}}):
        return
    call("PATCH", f"/v1/reviewSubmissions/{rsid}", {"data": {
        "type": "reviewSubmissions", "id": rsid, "attributes": {"submitted": True}}})
    print(f"      submitted {platform}")


def main():
    global TOK
    TOK = token()
    print(f"{'APPLY' if APPLY else 'PLAN (no writes)'} — {VERSION}, build {BUILD}"
          f"{', then SUBMIT' if SUBMIT else ''}\n")

    print("Subtitle / name")
    ensure_subtitle()

    for platform, cfg in PLATFORMS.items():
        print(f"\n{platform}")
        vid = ensure_version(platform)
        if not vid:
            if APPLY:
                problems.append(f"{platform}: no version id")
            continue
        lid = ensure_localization(vid, platform)
        ensure_build(vid, platform)
        if lid:
            for folder, display in cfg["shots"]:
                ensure_screenshots(lid, folder, display)
        if SUBMIT:
            submit(platform, vid)

    print("\n" + "=" * 60)
    print(("Would change: " if not APPLY else "Changed: ") + (", ".join(changes) or "nothing"))
    if problems:
        print("PROBLEMS:")
        for p in problems:
            print("  -", p)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
