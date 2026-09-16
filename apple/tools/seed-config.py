#!/usr/bin/env python3
"""Emit a Config JSON for the simulator, built from the synthetic fixture.

Writes to stdout so the caller decides where it lands. The shape has to match
`Config`'s decoder in `apple/Sources/CalMirrorKit/Config.swift`; every field is
lenient there, so a key this script gets wrong degrades to a default rather
than failing the load — which is worth knowing when a screen looks emptier
than expected.

**The page is left off, and with no slug.** Screens 1 and 2 are the state an
owner actually starts in, and the opt-in is the thing the privacy claim rests
on; seeding an enabled page would skip past the only part of this flow that
cannot be got wrong twice. Walk it from the beginning.

Never seeded from the live config — `review-fixture.json` is invented, which
is the same rule the screenshots follow.
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURE = ROOT / "tools" / "review-fixture.json"


def main() -> int:
    fx = json.loads(FIXTURE.read_text(encoding="utf-8"))
    owner, pol = fx["owner"], fx["policy"]

    def hhmm(label: str) -> str:
        """'9:00 AM' -> '09:00'. The fixture is written to be read aloud; the
        policy stores wall-clock 24h, and RequestPolicy refuses anything else."""
        t, _, mer = label.partition(" ")
        h, _, m = t.partition(":")
        h = int(h) % 12
        if mer.upper() == "PM":
            h += 12
        return f"{h:02d}:{m or '00'}"

    def lunch_pair(label: str) -> tuple[str, str]:
        """'12:00 – 1:30 PM' -> ('12:00', '13:30').

        The start carries no meridiem, so it inherits the end's — and if that
        ordering comes out backwards, it takes the other one. Getting this
        wrong is quiet: appending AM to a bare '12:00' turns noon into
        midnight, and the policy then keeps the whole morning clear while the
        screen still reads '12:00 to 1:30'.
        """
        start, _, end = label.partition("\u2013")
        start, end = start.strip(), end.strip()
        mer = end.rsplit(" ", 1)[-1].upper()
        mer = mer if mer in ("AM", "PM") else "PM"
        first = hhmm(f"{start} {mer}")
        second = hhmm(end)
        if first >= second:
            other = "AM" if mer == "PM" else "PM"
            first = hhmm(f"{start} {other}")
        return first, second

    lunch_from, lunch_to = lunch_pair(pol["lunch"])
    config = {
        "intervalSeconds": 1800,
        "paused": False,
        "realtime": True,
        "dedupeDestinations": False,
        "mirrors": [],
        "requestPage": {
            # Off. See the docstring — this is the point, not an oversight.
            "enabled": False,
            "slug": "",
            "displayName": owner["displayName"],
            "blurb": owner["blurb"],
            "meetingTitle": owner["meetingTitle"],
            "meetingLocation": owner["meetingLocation"],
            "blocking": [],
            "policy": {
                "horizonDays": int(pol["horizon"].split()[0]),
                "minNoticeHours": int(pol["notice"].split()[0]),
                "slotMinutes": int(pol["slot"].split()[0]),
                "align": 30,
                "bufferMinutes": int(pol["buffer"].split()[0]),
                "maxPerDay": int(pol["maxPerDay"]),
                "day": {"starts": hhmm(pol["dayStarts"]), "ends": hhmm(pol["dayEnds"])},
                "lunch": {"from": lunch_from, "to": lunch_to},
                "weekdays": ["mon", "tue", "wed", "thu", "fri"],
                "blackout": [],
                "timeZone": owner["timeZone"],
            },
        },
    }
    json.dump(config, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
