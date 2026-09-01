#!/usr/bin/env python3
"""Prototype: a self-contained availability page, everything baked in.

Emits ONE .html file with no external requests of any kind — no fonts, no
scripts, no fetch. That matters for three reasons:

  * There is no CORS problem, because there is no fetch. The availability is
    already in the file when it is written.
  * The owner can read the entire artifact before publishing it. Every byte a
    stranger can see is in one file you can open in a text editor. That is a
    much stronger claim than "trust our server", and it is the same argument the
    rest of the product makes.
  * It works anywhere a file can be served, and needs no build step.

The booking half never contacts anything either: picking a slot builds an
iCalendar REQUEST in the browser and hands it over as a download, with the
requester as ORGANIZER and the owner as ATTENDEE. The requester's own calendar
client is what sends the invitation.

    python3 make_availability.py --demo > availability.html

Real input is free/busy JSON on stdin:
    [{"start": "2026-09-01T09:00:00", "end": "2026-09-01T10:30:00"}, ...]
"""
import argparse, datetime as dt, html, json, sys

SLOT_MINUTES = 30


def free_slots(busy, days, day_start, day_end, slot_minutes, now):
    """Invert busy blocks into bookable slots inside working hours."""
    busy = sorted((b["start"], b["end"]) for b in busy)
    out = []
    for d in range(days):
        day = (now + dt.timedelta(days=d)).date()
        if day.weekday() >= 5:                      # weekends are not on offer
            continue
        t = dt.datetime.combine(day, dt.time(day_start))
        stop = dt.datetime.combine(day, dt.time(day_end))
        while t + dt.timedelta(minutes=slot_minutes) <= stop:
            end = t + dt.timedelta(minutes=slot_minutes)
            if t > now and not any(s < end and t < e for s, e in busy):
                out.append((t, end))
            t = end
    return out


PAGE = """<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{title}</title>
<style>
:root{{--bg:#f6f8fc;--card:#fff;--line:#e2e8f2;--tx:#0d1220;--mut:#4a5568;--accent:#3aa0ff;--accent2:#28c8b6}}
@media(prefers-color-scheme:dark){{:root{{--bg:#0b0e14;--card:#151b28;--line:#232c3d;--tx:#e6edf3;--mut:#93a1b5}}}}
*{{box-sizing:border-box}}
body{{margin:0;font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
color:var(--tx);background:var(--bg)}}
.wrap{{max-width:640px;margin:0 auto;padding:40px 22px 80px}}
h1{{font-size:28px;letter-spacing:-.5px;margin:.2em 0 .1em}}
.sub{{color:var(--mut);margin:0 0 26px;font-size:14.5px}}
.me{{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px 18px;margin-bottom:22px}}
.me label{{display:block;font-size:13px;color:var(--mut);margin:.5em 0 .2em}}
.me input{{width:100%;padding:9px 11px;border:1px solid var(--line);border-radius:9px;
background:var(--bg);color:var(--tx);font-size:15px}}
.day{{font-size:13px;font-weight:700;text-transform:uppercase;letter-spacing:.6px;
color:var(--mut);margin:22px 0 8px}}
.slots{{display:flex;flex-wrap:wrap;gap:8px}}
.slot{{background:var(--card);border:1px solid var(--line);border-radius:999px;
padding:8px 15px;font-size:14.5px;cursor:pointer;color:var(--tx)}}
.slot:hover{{border-color:var(--accent)}}
.slot[disabled]{{opacity:.5;cursor:default}}
.note{{color:var(--mut);font-size:13.5px;margin-top:30px;border-top:1px solid var(--line);padding-top:16px}}
.err{{color:#c0392b;font-size:13.5px;min-height:1.2em;margin-top:6px}}
</style></head><body><div class="wrap">
<h1>{title}</h1>
<p class="sub">Times I&rsquo;m usually free, as of {stamp}. Pick one and your calendar
app will send me an invitation &mdash; I&rsquo;ll accept or suggest another time.</p>

<div class="me">
  <label for="n">Your name</label><input id="n" placeholder="Alex Fisher">
  <label for="e">Your email</label><input id="e" type="email" placeholder="alex@example.com">
  <label for="w">What&rsquo;s it about? (optional)</label><input id="w" placeholder="Intro call">
  <div class="err" id="err"></div>
</div>

{slots}

<p class="note">This page is a single file. It makes no network requests, has no
analytics, and nothing you type here is sent anywhere &mdash; the invitation is
built in your browser and handed to your own calendar app. Because it is a
snapshot, a time shown free may have been taken since; I confirm every request.</p>
</div>
<script>
const OWNER = {owner_json};
function pad(n){{return String(n).padStart(2,'0')}}
function ical(d){{return d.getUTCFullYear()+pad(d.getUTCMonth()+1)+pad(d.getUTCDate())+'T'
  +pad(d.getUTCHours())+pad(d.getUTCMinutes())+'00Z'}}
function esc(s){{return String(s).replace(/([,;\\\\])/g,'\\\\$1').replace(/\\n/g,'\\\\n')}}
function book(startISO, endISO){{
  const name=document.getElementById('n').value.trim();
  const mail=document.getElementById('e').value.trim();
  const err=document.getElementById('err');
  if(!name||!mail.includes('@')){{err.textContent='Add your name and email first.';return}}
  err.textContent='';
  const what=document.getElementById('w').value.trim()||('Meeting with '+name);
  const s=new Date(startISO), e=new Date(endISO);
  // METHOD:REQUEST with the requester as ORGANIZER: their client is what sends
  // the invitation, so no server is involved on either side.
  const ics=['BEGIN:VCALENDAR','VERSION:2.0','PRODID:-//cal-mirror//availability//EN',
    'METHOD:REQUEST','BEGIN:VEVENT',
    'UID:'+Date.now()+'-'+Math.random().toString(36).slice(2)+'@cal-mirror',
    'DTSTAMP:'+ical(new Date()),'DTSTART:'+ical(s),'DTEND:'+ical(e),
    'SUMMARY:'+esc(what),
    'ORGANIZER;CN='+esc(name)+':mailto:'+mail,
    'ATTENDEE;CN='+esc(name)+';PARTSTAT=ACCEPTED;RSVP=FALSE:mailto:'+mail,
    'ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:'+OWNER.email,
    'DESCRIPTION:'+esc('Requested from '+location.href),
    'END:VEVENT','END:VCALENDAR'].join('\\r\\n');
  const url=URL.createObjectURL(new Blob([ics],{{type:'text/calendar;charset=utf-8'}}));
  const a=document.createElement('a');
  a.href=url; a.download='invite.ics'; document.body.appendChild(a); a.click(); a.remove();
  setTimeout(()=>URL.revokeObjectURL(url),5000);
  // Fallback for clients that open the file without sending anything: a plain
  // mailto, which cannot carry an attachment but always reaches a human.
  const body=encodeURIComponent(what+'\\n\\n'+s.toLocaleString()+' \\u2013 '+e.toLocaleTimeString()
    +'\\n\\nSent from '+location.href);
  document.getElementById('fb').innerHTML='Calendar app didn\\u2019t send it? '
    +'<a href="mailto:'+OWNER.email+'?subject='+encodeURIComponent(what)+'&body='+body+'">Email me instead</a>.';
}}
</script>
<div class="wrap" style="padding-top:0"><p class="note" id="fb"></p></div>
</body></html>
"""


def render(title, owner_email, slots, now):
    by_day, order = {}, []
    for s, e in slots:
        k = s.strftime("%A %-d %B")
        if k not in by_day:
            by_day[k] = []; order.append(k)
        by_day[k].append((s, e))
    blocks = []
    for k in order:
        btns = "".join(
            '<button class="slot" onclick="book(\'{}\',\'{}\')">{}</button>'.format(
                s.isoformat(), e.isoformat(), s.strftime("%-I:%M %p").lower())
            for s, e in by_day[k])
        blocks.append(f'<div class="day">{html.escape(k)}</div><div class="slots">{btns}</div>')
    return PAGE.format(title=html.escape(title),
                       stamp=now.strftime("%-I:%M %p on %-d %B %Y"),
                       slots="\n".join(blocks) or "<p>No free times in the window.</p>",
                       owner_json=json.dumps({"email": owner_email}))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--title", default="Book time with Matt")
    ap.add_argument("--email", default="x9f2k7@icloud.com", help="Hide My Email alias")
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--from-hour", type=int, default=9)
    ap.add_argument("--to-hour", type=int, default=17)
    ap.add_argument("--slot", type=int, default=SLOT_MINUTES)
    ap.add_argument("--demo", action="store_true", help="invent busy blocks")
    a = ap.parse_args()

    now = dt.datetime.now().replace(second=0, microsecond=0)
    if a.demo:
        base = now.replace(hour=0, minute=0)
        busy = []
        for d in range(a.days):
            day = base + dt.timedelta(days=d)
            busy.append({"start": day.replace(hour=9), "end": day.replace(hour=11)})
            busy.append({"start": day.replace(hour=13), "end": day.replace(hour=14, minute=30)})
    else:
        busy = [{"start": dt.datetime.fromisoformat(b["start"]),
                 "end": dt.datetime.fromisoformat(b["end"])} for b in json.load(sys.stdin)]

    slots = free_slots(busy, a.days, a.from_hour, a.to_hour, a.slot, now)
    sys.stdout.write(render(a.title, a.email, slots, now))


if __name__ == "__main__":
    main()
