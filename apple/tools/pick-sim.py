#!/usr/bin/env python3
"""Print the UDID of a simulator to use, or nothing if there is none.

Prefers, in order: one that is already booted (starting a second is slow and
makes `booted` ambiguous for every later simctl call), then one matching the
requested name, then any available iOS device.

A file rather than an inline `python3 -c` because this is called from a YAML
block scalar, where unindented lines inside a quoted string end the block and
produce a parse error several lines away from the cause.
"""
import json
import subprocess
import sys


def main() -> int:
    want = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        raw = subprocess.run(["xcrun", "simctl", "list", "devices", "available", "-j"],
                             capture_output=True, text=True, check=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return 1
    runtimes = json.loads(raw).get("devices", {})

    booted, named, ios = [], [], []
    for runtime, devices in runtimes.items():
        for d in devices:
            if d.get("state") == "Booted":
                booted.append(d)
            if want and d.get("name") == want:
                named.append(d)
            if "iOS" in runtime:
                ios.append(d)

    for pool in (booted, named, ios):
        if pool:
            print(pool[0]["udid"])
            return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
