#!/usr/bin/env python3
"""Bring the askwhen.me host in line with what is in this repo.

Runs ON the deployment host, against the local Docker daemon. It cannot deploy
remotely and there is no credential in this repository that could reach the box
— pull the repo there and run it there. That is a feature: a deploy script that
can reach production from a laptop can also reach production from a laptop that
has been left in a cafe.

It cannot touch DNS either. Every record in dns.md is created by hand, once, by
someone reading what they are typing.

Plans by default and writes nothing. `--apply` is the only thing that acts, the
same posture as .github/scripts/asc_apply.py, and for the same reason: a step
that already matches is skipped and says so, so a second run is quiet and safe.

    python3 infra/deploy.py                 # plan every step, write nothing
    python3 infra/deploy.py --apply         # do it
    python3 infra/deploy.py migrate --apply # one step
    python3 infra/deploy.py verify          # read-only probes, no --apply needed

Steps, in order:

    preflight   config and secrets present, sane, and not tracked by git
    build       docker compose build
    migrate     apply schema.sql — IRREVERSIBLE, see below
    up          docker compose up -d
    reload      validate the Caddyfile and reload it without dropping traffic
    verify      read-only probes: health, TLS, and that /internal is refused

IRREVERSIBLE: `migrate` writes to the live database. Every statement in
schema.sql is IF NOT EXISTS so re-running it is safe, but a *changed* schema.sql
is not a re-run — SQLite cannot drop a column, and a migration that loses a
column loses the rows in it. Take a copy of the volume first; `preflight` tells
you how.

Also irreversible, and not done here: creating DNS records, generating the DKIM
key, and rotating the token pepper. The pepper is the worst of the three —
changing it invalidates every write token in existence, there is no account to
recover one from, and every owner silently stops being able to publish.
"""
import os, shlex, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
COMPOSE = ["docker", "compose", "-f", os.path.join(HERE, "compose.yml")]

STEPS = ["preflight", "build", "migrate", "up", "reload", "verify"]
# verify is read-only and pointless in a plan, so a bare run stops before it.
DEFAULT = ["preflight", "build", "migrate", "up", "reload"]

APPLY = "--apply" in sys.argv
args = [a for a in sys.argv[1:] if not a.startswith("-")]
if "--help" in sys.argv or "-h" in sys.argv:
    print(__doc__)
    sys.exit(0)

changes, problems = [], []


def run(cmd, capture=False, check=True):
    """Actually execute something. Only ever called from inside act()."""
    r = subprocess.run(cmd, capture_output=capture, text=True)
    if check and r.returncode != 0:
        problems.append(shlex.join(cmd) + f" -> exit {r.returncode}")
    return r


def probe(cmd):
    """Read-only. Runs in plan mode too, because looking is not changing."""
    return subprocess.run(cmd, capture_output=True, text=True)


def ok(label):
    print(f"    = {label}")


def act(label, cmd, irreversible=False):
    """Print what would happen; do it only under --apply."""
    mark = "!!" if irreversible else "~ "
    print(f"    {mark} {label}")
    print(f"       {shlex.join(cmd)}")
    changes.append(label)
    if APPLY:
        run(cmd)


def fail(label):
    print(f"    ! {label}")
    problems.append(label)


# ------------------------------------------------------------------ preflight

def read_env():
    path = os.path.join(HERE, ".env")
    if not os.path.exists(path):
        return None
    out = {}
    for line in open(path):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def preflight():
    env = read_env()
    if env is None:
        fail(".env missing — cp env.example .env, fill it in, chmod 600")
        env = {}
    else:
        ok(".env present")
        for key in ("AW_ACME_EMAIL", "CF_API_TOKEN"):
            if env.get(key):
                ok(f"{key} set")
            else:
                fail(f"{key} empty in .env — see env.example for what it is")

    for name in ("smtp_password", "pepper"):
        path = os.path.join(HERE, "secrets", name)
        if not os.path.exists(path):
            fail(f"secrets/{name} missing — see README.md, Secrets")
            continue
        mode = os.stat(path).st_mode & 0o777
        if mode & 0o077:
            # Not fatal to Docker, fatal to the claim that this host is careful.
            fail(f"secrets/{name} is mode {mode:o} — chmod 600")
        elif os.path.getsize(path) == 0:
            fail(f"secrets/{name} is empty")
        else:
            ok(f"secrets/{name} present, mode {mode:o}")

    # The only check here that catches a mistake you cannot undo by editing a
    # file: a secret committed to a repository that gets pushed. git
    # check-ignore is cheap and answers exactly that question.
    for rel in (".env", "secrets"):
        p = os.path.join(HERE, rel)
        if not os.path.exists(p):
            continue
        if probe(["git", "-C", HERE, "check-ignore", "-q", p]).returncode == 0:
            ok(f"{rel} is gitignored")
        else:
            fail(f"{rel} is NOT gitignored — do not commit, fix .gitignore first")

    if probe(["docker", "compose", "version"]).returncode == 0:
        ok("docker compose available")
    else:
        fail("docker compose not available on this host")

    # Said rather than done. Backing up automatically would mean deciding where
    # to put a file containing requester email addresses, which is a decision
    # that belongs to whoever runs this, not to this.
    print("\n    Before `migrate --apply` on a database that already has rows:")
    print("       docker run --rm -v askwhen_aw-data:/d -v \"$PWD\":/b alpine \\")
    print("         cp /d/askwhen.db /b/askwhen-$(date +%F).db")


# ---------------------------------------------------------------------- steps

def build():
    act("build the app image", COMPOSE + ["build"])


def migrate():
    # Applied by the binary itself, against the schema.sql embedded at build
    # time (see Dockerfile). Doing it here with a sqlite3 CLI would mean either
    # putting a shell in the distroless image or trusting that the file on disk
    # matches the file that was reviewed.
    act("apply schema.sql to /data/askwhen.db",
        COMPOSE + ["run", "--rm", "app", "-migrate"], irreversible=True)


def up():
    act("start or update containers", COMPOSE + ["up", "-d"])


def reload():
    # Validate first. A reload with a bad Caddyfile leaves the old config
    # running, which is the good outcome — but only if you notice, and the
    # error scrolls past in a log nobody is reading.
    r = probe(COMPOSE + ["exec", "-T", "caddy",
                         "caddy", "validate", "--config", "/etc/caddy/Caddyfile"])
    if r.returncode == 0:
        ok("Caddyfile validates")
        act("reload Caddy without dropping connections",
            COMPOSE + ["exec", "-T", "caddy",
                       "caddy", "reload", "--config", "/etc/caddy/Caddyfile"])
    elif "No such container" in (r.stderr or "") or "not running" in (r.stderr or ""):
        # First deploy: `up` just started it with the config already in place.
        ok("caddy not running yet — `up` will have loaded the config")
    else:
        fail("Caddyfile does not validate:\n" + (r.stderr or r.stdout).strip())


def verify():
    """Read-only. Nothing here writes, so it runs without --apply."""
    checks = [
        ("app answers its health check",
         COMPOSE + ["exec", "-T", "app", "/askwhen", "-healthcheck"], None),
        ("apex serves over TLS",
         ["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}",
          "https://askwhen.me/"], "200"),
        # The one that matters. If this ever answers anything but 404 from
        # outside, on-demand TLS is an open certificate mint.
        ("/internal is refused from outside",
         ["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}",
          "https://askwhen.me/internal/tls-authorize?domain=example.net"], "404"),
    ]
    for label, cmd, expect in checks:
        r = probe(cmd)
        got = (r.stdout or "").strip()
        if r.returncode != 0:
            fail(f"{label} — command failed: {(r.stderr or '').strip()[:200]}")
        elif expect and got != expect:
            fail(f"{label} — expected {expect}, got {got or '(nothing)'}")
        else:
            ok(label)

    print("\n    Mail is not verified from here. dlvr.rehosted.us is a different")
    print("    host and this script has no route to it — mail.md, 'Verifying'.")


ACTIONS = dict(preflight=preflight, build=build, migrate=migrate,
               up=up, reload=reload, verify=verify)


def main():
    wanted = args or DEFAULT
    for name in wanted:
        if name not in ACTIONS:
            print(f"unknown step {name!r}; one of: {', '.join(STEPS)}")
            return 2

    print(("APPLY" if APPLY else "PLAN (no writes)") + " — " + ", ".join(wanted))
    if not APPLY:
        print("Nothing below will run. Add --apply when you mean it.\n")
    else:
        print()

    for name in wanted:
        print(name)
        ACTIONS[name]()
        print()

    print("=" * 60)
    print(("Would run: " if not APPLY else "Ran: ") + (", ".join(changes) or "nothing"))
    if problems:
        print("PROBLEMS:")
        for p in problems:
            print("  -", p)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
