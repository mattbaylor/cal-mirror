#!/usr/bin/env python3
"""Generate the end-to-end review page for the request-page UI.

`contact-sheet.html` is frames at true size, for marking up words and layout.
This is the other half: the whole journey in order, with the reasoning and the
open questions attached to the screens they belong to, so the flow can be
argued with rather than only looked at.

Both are generated. Copy comes from `Shared/RequestPage/Copy.json` — the same
file the app's strings come from — and the example data comes from
`tools/review-fixture.json`, which is synthetic on purpose: the live config
holds a work email, an employer, a spouse's calendar and children's names, and
the rule against using it should be satisfied by where the data comes from
rather than by whoever runs this remembering to be careful.
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
COPY = ROOT / "Shared" / "RequestPage" / "Copy.json"
FIXTURE = ROOT / "tools" / "review-fixture.json"
OUT = ROOT / "tools" / "review.html"


def esc(s):
    return str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def fmt(template, *args):
    """Apply a Swift format string (%@ / %d) with Python values."""
    out = template
    for a in args:
        for token in ("%@", "%d"):
            if token in out:
                out = out.replace(token, str(a), 1)
                break
    return out


STAGES = [
    ("local", "On the device only", "No network request has been made at this point."),
    ("apple", "Apple", "StoreKit. The app's first network request of any kind."),
    ("service", "askwhen.me", "The dead drop: slots out, requests in."),
]


def step(n, title, stage, what, why, screen, open_q=None):
    q = (f'<div class="open"><b>Open</b> — {esc(open_q)}</div>' if open_q else "")
    return f"""
    <section class="step">
      <div class="left">
        <div class="num">{n}</div>
        <div class="rail stage-{stage}"></div>
      </div>
      <div class="mid">
        <h3>{esc(title)}</h3>
        <span class="tag tag-{stage}">{esc(dict((s[0], s[1]) for s in STAGES)[stage])}</span>
        <p class="what">{esc(what)}</p>
        <p class="why"><b>Why</b> — {esc(why)}</p>
        {q}
      </div>
      <div class="right">{screen}</div>
    </section>"""


def phone(inner, caption=None):
    cap = f'<p class="cap">{esc(caption)}</p>' if caption else ""
    return f'<div class="scr">{inner}</div>{cap}'


def nav(t):
    return f'<div class="nav">{esc(t)}</div>'


def grp(inner):
    return f'<div class="grp">{inner}</div>'


def pad(inner):
    return f'<div class="pad">{inner}</div>'


def build(c, fx):
    o, pol, pv, rq, cf = fx["owner"], fx["policy"], fx["preview"], fx["request"], fx["conflict"]
    d, e, cal = c["dormantRow"], c["explainer"], c["calendars"]
    dsp, po, prv = c["display"], c["policy"], c["preview"]
    off, lv, nt, cs = c["offer"], c["live"], c["notification"], c["conflict"]

    steps = []

    steps.append(step(1, "The dormant row", "local",
        "One row in a list the owner already uses. Off, and drawing it costs nothing.",
        "An owner who never taps it keeps exactly the privacy position 1.x had — no account, no server, no traffic.",
        phone(nav("Calendar Mirror") + grp(
            f'<div class="row"><div class="rowmain"><span class="t">{esc(d["title"])}</span>'
            f'<span class="val">{esc(d["off"])}</span><span class="chev">›</span></div>'
            f'<p class="cap">{esc(d["blurbPhone"])}</p></div>'))))

    steps.append(step(2, "What this is", "local",
        "The explainer, and the opt-in. Long on purpose — this is where someone decides whether to have a server in their life.",
        "The cost is named here, before any work is asked of them, so the price at step 7 is disclosed rather than sprung.",
        phone(nav("Request page") + pad(
            f'<h4>{esc(e["title"])}</h4>'
            + "".join(f'<p class="body">{esc(p)}</p>' for p in e["paragraphs"])
            + f'<p class="sub">{esc(e["costHeading"])}</p><p class="body">{esc(e["cost"])}</p>'
            + f'<div class="btn">{esc(e["primary"])}</div>'
            + f'<p class="foot">{esc(e["footnote"])}</p>'))))

    rows = "".join(
        f'<div class="calrow"><span class="t">{esc(x["name"])}</span>'
        f'<span class="pill {"on" if x["blocking"] else ""}">{esc(cal["blockTitle"])}</span>'
        f'<span class="pill {"on" if x["request"] else ""}">{esc(cal["useTitle"])}</span></div>'
        for x in fx["calendars"])
    steps.append(step(3, "Which calendars count", "local",
        "Two checkboxes per calendar, in the window the owner already uses to look at their calendars.",
        "Use for requests is exactly one, enforced at the control rather than by a validation message — the Kit writes into a single CalRef.",
        phone(nav("Manage Mirrors") + grp(
            f'<div class="hdr">{esc(cal["section"])}</div>{rows}'
            f'<p class="cap pad8 priv">{esc(cal["privacy"])}</p>'))))

    steps.append(step(4, "Your page", "local",
        "Display name, blurb, and the title the accepted event gets.",
        "The display name is the only identifying field in the dump. The event title is the owner's, because a stranger naming an event puts unreviewed text in a calendar.",
        phone(nav(esc(dsp["section"])) + grp(
            f'<div class="row"><div class="rowmain"><span class="t">{esc(dsp["nameTitle"])}</span>'
            f'<span class="val">{esc(o["displayName"])}</span></div>'
            f'<p class="cap">{esc(dsp["nameCaption"])}</p></div>'
            f'<div class="row"><div class="rowmain"><span class="t">{esc(dsp["blurbTitle"])}</span></div>'
            f'<p class="body sm">{esc(o["blurb"])}</p></div>')
            + grp(f'<div class="hdr">{esc(dsp["meetingSection"])}</div>'
                  f'<div class="row"><div class="rowmain"><span class="t">{esc(dsp["titleTitle"])}</span>'
                  f'<span class="val">{esc(o["meetingTitle"])}</span></div>'
                  f'<p class="cap">{esc(dsp["titleCaption"])}</p></div>'))))

    days = "".join(f'<span class="day {"on" if x in "MTWTF" else ""}">{x}</span>'
                   for x in ["S", "M", "T", "W", "T", "F", "S"])
    nums = "".join(
        f'<div class="row"><div class="rowmain"><span class="t">{esc(t)}</span>'
        f'<span class="val">{esc(v)}</span></div></div>'
        for t, v in [(po["horizonTitle"], pol["horizon"]), (po["noticeTitle"], pol["notice"]),
                     (po["maxPerDayTitle"], pol["maxPerDay"]), (po["slotTitle"], pol["slot"]),
                     (po["alignTitle"], pol["align"]), (po["bufferTitle"], pol["buffer"])])
    steps.append(step(5, "Your day", "local",
        "The policy, asked as a sentence that reads aloud, with the zone stated on the line rather than inferred from the device.",
        "maxPerDay and the horizon are privacy controls wearing the clothes of preferences — publishing every free half-hour tells a stranger your week is empty.",
        phone(nav(esc(po["section"])) + grp(pad(
            f'<p class="say"><b>{esc(po["dayStarts"])}</b> <u>{esc(pol["dayStarts"])}</u> '
            f'<b>{esc(po["dayEnds"])}</b> <u>{esc(pol["dayEnds"])}</u><br>'
            f'<b>{esc(po["zoneTitle"])}</b> <u>{esc(o["timeZone"])}</u><br>'
            f'<b>{esc(po["lunchTitle"])}</b> <u>{esc(pol["lunch"])}</u><br>'
            f'<b>{esc(po["weekdaysTitle"])}</b> {days}</p>')) + grp(nums)),
        open_q="Six numbered settings under the sentence. decisions.md argues for few settings and good defaults — buffer, align and slot length could fold behind a disclosure."))

    gridrows = "".join(
        f'<div class="dayrow"><span class="dl">{esc(lbl)}</span><span class="chips">'
        + ("".join(f'<span class="slot">{esc(t)}</span>' for t in times)
           or '<span class="empty">nothing offered</span>')
        + "</span></div>"
        for lbl, times in pv["grid"])
    steps.append(step(6, "What people see", "local",
        "The real offers this policy makes against this calendar, on real dates, before anyone else can see them.",
        "The only honest demonstration the product has — and the empty-day accounting is the one question a settings screen cannot answer.",
        phone(nav(esc(prv["section"])) + grp(
            pad(f'<h4>{esc(fmt(prv["headingMany"], pv["offered"], pv["days"]))}</h4>'
                f'<p class="cap">{esc(prv["stale"])}</p>') + gridrows)
            + grp(f'<div class="hdr">{esc(prv["emptyDayHeading"])}</div>'
                  f'<p class="body sm pad8"><b>{esc(pv["emptyDay"]["label"])}</b> — {esc(pv["emptyDay"]["reasons"])}</p>')
            + grp(f'<p class="cap pad8 priv">{esc(prv["privacy"])}</p>'))))

    steps.append(step(7, "Publishing", "apple",
        "The offer. The Request Page trial is the single live action; the two paid tiers are shown as upgrades, not sold here.",
        "Apple grants one introductory offer per customer per group, so a three-way picker with one free option is a free option with two decoys.",
        phone(nav(esc(off["section"])) + grp(pad(
            f'<h4>{esc(off["heading"])}</h4><p class="body sm">{esc(off["lede"])}</p>'))
            + grp(pad('<p class="body"><b>AskWhen.me Request Page</b></p>'
                      f'<p class="body"><b>{esc(fmt(off["trialLine"], "3 months free", "$19.99"))}</b></p>'
                      f'<div class="btn">{esc(off["buyWithTrial"])}</div>'
                      f'<p class="foot">{esc(off["renews"])}</p>')
                  + f'<p class="cap pad8 priv">{esc(off["network"])}</p>')
            + grp(f'<div class="hdr">{esc(off["upgradesHeading"])}</div>'
                  '<div class="row"><div class="rowmain"><span class="t">Custom Subdomain</span><span class="val">$34.99</span></div></div>'
                  '<div class="row"><div class="rowmain"><span class="t">Custom Domain</span><span class="val">$69.99</span></div></div>')
            + grp(f'<div class="row"><div class="rowmain"><span class="t">{esc(off["restore"])}</span></div></div>')),
        open_q="A returning owner has no trial left, and sees the price plainly instead. That variant is 7b on the contact sheet."))

    steps.append(step(8, "Apple's sheet, then the page", "service",
        "StoreKit takes the payment method; the device sends Apple's signed transaction and askwhen.me returns a slug and a write token.",
        "The service verifies Apple's signature itself and derives the entitlement — it never learns a name, an address or a card, and the device never sends a hash it could have made up.",
        phone(nav(esc(off["section"])) + grp(pad(
            f'<p class="body">{esc(off["creating"])}</p>'))
            + grp(pad(f'<p class="body sm"><b>{esc(off["createFailedTitle"])}</b></p>'
                      f'<p class="cap">{esc(off["createFailedBody"])}</p>')))))

    steps.append(step(9, "Your page is live", "local",
        "The URL, the notification permission, and the two facts an owner hears exactly once.",
        "The write token lives only in this keychain and cannot be recovered — there is no account to recover it to. Saying so here is the difference between a design property and a support ticket.",
        phone(nav(esc(lv["section"])) + grp(pad(
            f'<h4>{esc(lv["heading"])}</h4><p class="body sm">{esc(lv["lede"])}</p>'
            f'<p class="mono">askwhen.me/{esc(o["slug"])}</p>'
            f'<div class="btn">{esc(lv["copy"])}</div>'))
            + grp(f'<div class="hdr">{esc(nt["permissionHeading"])}</div>'
                  f'<p class="body sm pad8">{esc(nt["permissionBody"])}</p>'
                  f'<p class="cap pad8">{esc(nt["permissionNote"])}</p>')
            + grp(f'<div class="hdr">{esc(lv["tokenHeading"])}</div>'
                  f'<p class="body sm pad8">{esc(lv["tokenBody"])}</p>')),
        open_q="Screen 10 (which device publishes) is folded in here — a nomination screen with one candidate asks a question with no second answer."))

    steps.append(step(10, "Someone asks", "service",
        "A stranger picks a time, confirms by email, and the device collects it on the next poll. A notification arrives carrying Accept and Decline.",
        "Nothing is pushed to the owner — the service holds no address for them. The device collects, so the notification is not a convenience on top of a feed; it is the arrival.",
        phone('<div class="notif"><div class="napp">CALENDAR MIRROR</div>'
              f'<div class="ntitle">{esc(fmt(nt["titleFormat"], rq["name"]))}</div>'
              f'<div class="nsub">{esc(rq["slot"])}</div>'
              f'<div class="nbody">{esc(rq["note"])}</div>'
              f'<div class="nactions"><span>{esc(nt["decline"])}</span><span class="prim">{esc(nt["accept"])}</span></div>'
              "</div>"
              + grp(f'<div class="hdr">Waiting for you</div>'
                    f'<div class="pad"><p class="body"><b>{esc(rq["slot"])}</b></p>'
                    f'<p class="cap">{esc(rq["name"])} · {esc(rq["email"])}</p>'
                    f'<p class="body sm">{esc(rq["note"])}</p>'
                    f'<div class="btnrow"><span class="btn sm">{esc(nt["accept"])}</span>'
                    f'<span class="btn sm ghostbtn">{esc(nt["decline"])}</span></div></div>'))))

    alts = "".join(f'<div class="row"><div class="rowmain"><span class="t">{esc(a)}</span></div></div>'
                   for a in cf["alternatives"])
    steps.append(step(11, "The slot is gone", "local",
        "Accept re-checks the calendar first. If something landed since the time was offered, nothing is written and nobody is told.",
        "This is the one thing this architecture does better than a hosted competitor: the device holds the truth, so it notices before writing. A hosted service believes its own copy.",
        phone(nav("Request conflict") + grp(pad(
            f'<h4>{esc(cs["title"])}</h4>'
            f'<p class="body sm">{esc(fmt(cs["lede"], rq["name"], rq["slot"]))}</p>'))
            + grp(f'<div class="hdr">{esc(cs["landedHeading"])}</div>'
                  f'<div class="row"><div class="rowmain"><span class="t">{esc(cf["landed"])}</span></div></div>'
                  f'<p class="cap pad8">{esc(cs["landedNote"])}</p>')
            + grp(f'<div class="hdr">{esc(cs["alternativesHeading"])}</div>{alts}'
                  f'<p class="cap pad8">{esc(cs["alternativesNote"])}</p>')
            + grp(f'<div class="row"><div class="rowmain"><span class="t danger">{esc(cs["decline"])}</span></div></div>'
                  f'<div class="row"><div class="rowmain"><span class="t">{esc(cs["later"])}</span></div></div>')
            + grp(f'<div class="row"><div class="rowmain"><span class="t">{esc(cs["acceptAnyway"])}</span></div></div>'
                  f'<p class="cap pad8">{esc(cs["acceptAnywayNote"])}</p>')),
        open_q="\"What landed\" is a time, never a title — BusyInterval carries no title by design. Whether the owner should see their own event's name here is your call, and it means a new path through the privacy boundary."))

    lp, dm = c["lapse"], c["domains"]
    fd, fl = fx["domains"], fx["lapse"]

    def field_row(label, value, suffix=None, ghost=True):
        sfx = f'<span class="sfx">{esc(suffix)}</span>' if suffix else ""
        cls = "input ghost" if ghost else "input"
        return (f'<div class="pad"><p class="cap">{esc(label)}</p>'
                f'<div class="fieldrow"><span class="{cls}">{esc(value)}</span>{sfx}</div></div>')

    steps.append(step(12, "Claiming an address", "service",
        "The slug always works. On top of it the owner types either a label for a subdomain of askwhen.me, or a domain they already own.",
        "Whatever is typed is normalized before it is claimed \u2014 case folded, trimmed, a pasted URL reduced to its host, a trailing dot dropped. Each of those is a correct answer arriving looking wrong, and each would otherwise claim a hostname that can never verify.",
        phone(nav(esc(dm["section"])) + grp(pad(
            f'<p class="cap">{esc(dm["current"])}</p><p class="mono">askwhen.me/{esc(o["slug"])}</p>'
            f'<p class="cap">{esc(dm["slugNote"])}</p>'))
            + grp(f'<div class="hdr">{esc(dm["subdomainHeading"])}</div>'
                  f'<p class="body sm pad8">{esc(dm["subdomainBody"])}</p>'
                  + field_row("", dm["subdomainPlaceholder"], dm["subdomainSuffix"])
                  + f'<div class="pad"><div class="btn">{esc(dm["claim"])}</div></div>')
            + grp(f'<div class="hdr">{esc(dm["customHeading"])}</div>'
                  f'<p class="body sm pad8">{esc(dm["customBody"])}</p>'
                  + field_row("", dm["customPlaceholder"])
                  + f'<div class="pad"><div class="btn">{esc(dm["claim"])}</div></div>')),
        open_q="The field is offered only on a tier that includes it; otherwise the same section shows why, and an Upgrade button. That variant is 12b."))

    steps.append(step("12b", "On a tier without it", "apple",
        "The same two sections, with the reason and an upgrade in place of the field \u2014 rather than an input that would be refused.",
        "This is where the $35 and $70 tiers are actually sold, which is the whole argument for not selling them during setup: a nicer address is worth nothing before there is a page at it.",
        phone(nav(esc(dm["section"])) + grp(
            f'<div class="hdr">{esc(dm["subdomainHeading"])}</div>'
            f'<p class="body sm pad8">{esc(dm["subdomainBody"])}</p>'
            f'<p class="cap pad8">{esc(dm["needsSubdomainTier"])}</p>'
            f'<div class="pad"><div class="btn">{esc(dm["upgrade"])}</div>'
            f'<p class="foot">{esc(dm["upgradeNote"])}</p></div>')
            + grp(f'<div class="hdr">{esc(dm["customHeading"])}</div>'
                  f'<p class="body sm pad8">{esc(dm["customBody"])}</p>'
                  f'<p class="cap pad8">{esc(dm["needsDomainTier"])}</p>'
                  f'<div class="pad"><div class="btn">{esc(dm["upgrade"])}</div></div>'))))

    steps.append(step(13, "Waiting for DNS", "service",
        "A subdomain verifies on arrival and has nothing more to say. A custom domain comes back unverified, carrying the CNAME to set and what DNS answers instead.",
        "Checking is not a refresh button \u2014 GET /domains makes the service re-read DNS and issue the certificate the moment the record is right, so asking is what makes it start working. The service\u2019s own diagnosis is shown verbatim, because it knows what DNS answered and the device does not.",
        phone(nav(esc(dm["section"])) + grp(pad(
            f'<p class="body"><span class="mono sm">{esc(fd["subdomain"])}</span> '
            f'<span class="ok">\u2713 {esc(dm["verified"])}</span></p>'))
            + grp(pad(f'<p class="body"><span class="mono sm">{esc(fd["custom"])}</span> '
                      f'<span class="pend">\u25f7 {esc(dm["pending"])}</span></p>'
                      f'<p class="cap">{esc(dm["cnameHeading"])}</p>'
                      f'<p class="mono sm">{esc(fmt(dm["cnameFormat"], fd["custom"], fd["point"]))}</p>'
                      f'<p class="cap">{esc(dm["sawHeading"])}</p>'
                      f'<p class="mono sm">{esc(fd["check"])}</p>'
                      f'<p class="body sm">{esc(fd["advice"])}</p>'
                      f'<div class="btn">{esc(dm["check"])}</div>'
                      f'<p class="foot">{esc(dm["checkNote"])}</p>')))))

    steps.append(step(14, "The subscription ends", "service",
        "Seven days of grace. The page stays up saying \u201cnot currently taking requests\u201d, then askwhen.me deletes it and the link 404s.",
        "That line is the same one a page shows when the publisher has been offline a while, so a visitor learns nothing about the owner\u2019s billing. Renewing inside the grace brings the same page back at the same address, which is the fact that decides whether someone renews.",
        phone(nav(esc(lv["section"])) + grp(pad(
            f'<p class="body"><b>⚠ {esc(lp["graceHeading"])}</b></p>'
            f'<p class="body sm">{esc(lp["graceBody"])}</p>'
            f'<p class="body"><b>{esc(fmt(lp["graceCountMany"], fl["daysLeft"]))}</b></p>'
            f'<p class="cap">{esc(lp["graceWhatGoes"])}</p>'
            f'<p class="body sm">{esc(lp["graceFix"])}</p>'
            f'<div class="btn">{esc(lp["renew"])}</div>'))),
        open_q="The device counts the grace down, but the service is the authority — it deletes from Apple\u2019s server notifications and this device may have slept through it. Finding the slug gone is what settles it."))

    steps.append(step(15, "It is gone", "service",
        "The grace ran out. The page, its address and its queue are removed; a new subscription starts a new page at a new address.",
        "The sentence that matters is that the calendar is untouched \u2014 every request already accepted is an ordinary event that never depended on the page staying up.",
        phone(nav(esc(lv["section"])) + grp(pad(
            f'<p class="body"><b>{esc(lp["goneHeading"])}</b></p>'
            f'<p class="body sm">{esc(lp["goneBody"])}</p>'
            f'<p class="cap">{esc(lp["goneCalendar"])}</p>'
            f'<div class="btn">{esc(lp["startAgain"])}</div>')))))

    return "".join(steps)


CSS = """
:root {
  color-scheme: light dark;
  --page:#eef1f6; --ink:#0d1220; --note:#5a6a80; --edge:#d3dae6;
  --card:#fff; --grp:#f4f6fa; --tint:#0a63d2; --sep:#e4e8f0;
  --local:#2f8f5b; --apple:#8a5cd6; --service:#c2691f; --warn:#8a6d1f;
}
@media (prefers-color-scheme: dark) {
  :root {
    --page:#070910; --ink:#e6edf3; --note:#8b9bb0; --edge:#1e2634;
    --card:#111621; --grp:#161c27; --tint:#5aa2ff; --sep:#232b39;
    --local:#57c98c; --apple:#b28cf0; --service:#e0964f; --warn:#d8b45a;
  }
}
* { box-sizing: border-box; }
body { margin:0; background:var(--page); color:var(--ink); padding:40px 24px 80px;
  font:15px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif; }
.wrap { max-width: 1120px; margin: 0 auto; }
h1 { font-size:30px; margin:0 0 6px; letter-spacing:-.4px; }
.lede { color:var(--note); max-width:76ch; margin:0 0 18px; font-size:16px; }
.meta { display:flex; flex-wrap:wrap; gap:8px; margin:0 0 26px; }
.chip { font-size:12px; border:1px solid var(--edge); border-radius:99px; padding:4px 11px; color:var(--note); }
.warnbox { border-left:3px solid var(--warn); padding:10px 14px; margin:0 0 34px;
  background:var(--grp); border-radius:0 8px 8px 0; font-size:13.5px; color:var(--note); max-width:80ch; }
.warnbox b { color:var(--ink); }
.legend { display:flex; flex-wrap:wrap; gap:18px; margin:0 0 34px; font-size:13px; }
.legend div { display:flex; align-items:center; gap:7px; color:var(--note); }
.dot { width:10px; height:10px; border-radius:99px; flex:none; }
.step { display:grid; grid-template-columns:44px 1fr 390px; gap:20px; margin:0 0 14px;
  align-items:start; padding-bottom:26px; border-bottom:1px solid var(--sep); }
.left { display:flex; flex-direction:column; align-items:center; height:100%; }
.num { width:32px; height:32px; border-radius:99px; background:var(--card); border:1px solid var(--edge);
  display:flex; align-items:center; justify-content:center; font-size:14px; font-weight:600; flex:none; }
.rail { width:2px; flex:1; margin-top:8px; min-height:40px; border-radius:2px; }
.stage-local { background:var(--local); } .stage-apple { background:var(--apple); } .stage-service { background:var(--service); }
.mid h3 { font-size:19px; margin:2px 0 8px; }
.tag { font-size:11px; padding:3px 9px; border-radius:99px; text-transform:uppercase; letter-spacing:.5px; }
.tag-local { background:color-mix(in srgb, var(--local) 16%, transparent); color:var(--local); }
.tag-apple { background:color-mix(in srgb, var(--apple) 16%, transparent); color:var(--apple); }
.tag-service { background:color-mix(in srgb, var(--service) 16%, transparent); color:var(--service); }
.what { margin:12px 0 8px; }
.why { margin:0 0 10px; color:var(--note); font-size:14px; }
.why b { color:var(--ink); }
.open { border-left:3px solid var(--warn); padding:8px 12px; font-size:13px; color:var(--note);
  background:var(--grp); border-radius:0 6px 6px 0; }
.open b { color:var(--warn); }
.scr { width:390px; max-width:100%; background:var(--grp); border:1px solid var(--edge);
  border-radius:14px; overflow:hidden; }
.nav { padding:12px 16px; font-weight:600; font-size:17px; background:var(--card); border-bottom:1px solid var(--sep); }
.grp { background:var(--card); margin:12px 0; border-top:1px solid var(--sep); border-bottom:1px solid var(--sep); }
.hdr { font-size:11.5px; text-transform:uppercase; letter-spacing:.5px; color:var(--note); padding:13px 16px 5px; }
.row { padding:11px 16px; border-bottom:1px solid var(--sep); }
.row:last-child { border-bottom:0; }
.rowmain { display:flex; align-items:center; gap:8px; }
.t { flex:1; } .t.danger { color:#c0392b; }
.val { color:var(--note); } .chev { color:var(--note); }
.cap { color:var(--note); font-size:12.5px; margin:6px 0 0; }
.pad8 { padding:0 16px 10px; } .priv { border-top:1px solid var(--sep); padding-top:10px; }
.pad { padding:16px; background:var(--card); }
h4 { font-size:18px; margin:0 0 6px; }
.body { font-size:14.5px; margin:0 0 10px; } .body.sm { font-size:13.5px; }
.sub { font-size:11.5px; text-transform:uppercase; letter-spacing:.5px; color:var(--note); margin:16px 0 5px; }
.btn { background:var(--tint); color:#fff; text-align:center; padding:12px; border-radius:9px;
  font-weight:600; margin:16px 0 10px; font-size:14px; }
.btn.sm { padding:8px 16px; margin:0; display:inline-block; }
.ghostbtn { background:transparent; color:var(--tint); border:1px solid var(--tint); }
.btnrow { display:flex; gap:8px; margin-top:10px; }
.foot { color:var(--note); font-size:12px; margin:0; }
.calrow { display:flex; align-items:center; gap:6px; padding:10px 16px; border-bottom:1px solid var(--sep); }
.pill { font-size:10.5px; padding:3px 8px; border-radius:99px; white-space:nowrap;
  border:1px solid var(--sep); color:var(--note); }
.pill.on { background:var(--tint); border-color:var(--tint); color:#fff; }
.say { font-size:15px; line-height:2.1; margin:0; }
.say u { text-decoration:none; border-bottom:1.5px dashed var(--tint); color:var(--tint); padding:1px 3px; }
.day { display:inline-block; width:23px; height:23px; line-height:23px; text-align:center;
  border-radius:99px; font-size:11.5px; margin-right:3px; background:var(--sep); color:var(--note); }
.day.on { background:var(--tint); color:#fff; }
.dayrow { display:flex; gap:10px; align-items:baseline; padding:9px 16px; border-top:1px solid var(--sep); }
.dl { width:56px; color:var(--note); font-size:12.5px; flex:none; }
.chips { display:flex; flex-wrap:wrap; gap:5px; }
.slot { font-size:12px; padding:3px 9px; border-radius:6px; border:1px solid var(--tint); color:var(--tint); }
.empty { font-size:12px; color:var(--note); font-style:italic; }
.mono { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:17px; margin:14px 0 0; word-break:break-all; }
.mono.sm { font-size:12.5px; margin:4px 0 10px; }
.ok { color:var(--local); font-size:12.5px; }
.pend { color:var(--service); font-size:12.5px; }
.fieldrow { display:flex; align-items:center; gap:4px; margin-top:2px; }
.input { flex:1; border:1px solid var(--edge); border-radius:7px; padding:9px 11px;
  background:var(--grp); font-size:14px; }
.input.ghost { color:var(--note); }
.sfx { color:var(--note); font-size:14px; }
.notif { background:var(--card); border:1px solid var(--edge); border-radius:14px; padding:13px 15px; margin:12px; }
.napp { font-size:10.5px; letter-spacing:.7px; color:var(--note); margin-bottom:5px; }
.ntitle { font-weight:600; font-size:15px; }
.nsub { font-size:14px; color:var(--ink); margin-top:1px; }
.nbody { font-size:13.5px; color:var(--note); margin-top:5px; }
.nactions { display:flex; gap:10px; margin-top:12px; border-top:1px solid var(--sep); padding-top:10px; font-size:14px; }
.nactions span { flex:1; text-align:center; color:var(--tint); }
.nactions .prim { font-weight:600; }
@media (max-width: 900px) {
  .step { grid-template-columns:34px 1fr; }
  .right { grid-column:2; }
  .scr { width:100%; }
}
"""


def main():
    c = json.loads(COPY.read_text(encoding="utf-8"))
    fx = json.loads(FIXTURE.read_text(encoding="utf-8"))
    legend = "".join(
        f'<div><span class="dot stage-{k}"></span>{esc(t)} — {esc(sub)}</div>'
        for k, t, sub in STAGES)
    html = f"""<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width,initial-scale=1" />
    <meta name="robots" content="noindex,nofollow" />
    <title>Request page — end to end</title>
    <!-- GENERATED by tools/gen-review.py from Shared/RequestPage/Copy.json and
         tools/review-fixture.json. Do not edit this file. -->
    <style>{CSS}</style>
  </head>
  <body>
    <div class="wrap">
      <h1>The request page, end to end</h1>
      <p class="lede">Fifteen steps from an owner who has never heard of this to a stranger
        asking for a time and being answered — and on to a nicer address, and to what happens when the subscription stops. Every screen carries what it does, why it is
        that way, and anything still open on it.</p>
      <div class="meta">
        <span class="chip">Calendar Mirror 2.0</span>
        <span class="chip">Copy generated from Copy.json</span>
        <span class="chip">Data from review-fixture.json — synthetic</span>
        <span class="chip">Light and dark follow your system</span>
      </div>
      <div class="warnbox">
        <b>What this is and is not.</b> The words, the order and the reasoning are real — the
        copy is generated from the same file the app's strings are, so it cannot drift.
        The rendering is not: this is HTML and the app is SwiftUI, so spacing, type and color
        come from the simulator, not from here. Nothing in it has been compiled — there is no
        Swift toolchain in the session that wrote it, and CI is the first real build.
        Every name, calendar and time below is invented; the live config is never used for this.
      </div>
      <div class="legend">{legend}</div>
      {build(c, fx)}
    </div>
  </body>
</html>
"""
    OUT.write_text(html, encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
