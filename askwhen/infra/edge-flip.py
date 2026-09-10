"""Enable on-demand TLS on caddy-dc. Reads the gate secret from stdin; writes
nothing else anywhere. Idempotent: a second run finds its own markers and stops."""
import sys, shutil, datetime
KEY = sys.stdin.read().strip()
assert len(KEY) == 64, "secret is not 64 hex characters"
P = "/opt/caddy/Caddyfile"
src = open(P).read()
if "on_demand_tls" in src:
    print("already enabled"); sys.exit(0)
shutil.copy(P, P + ".bak-" + datetime.date.today().isoformat() + "-step6")

GLOBAL = f"""# Global options. Added 10 Sept 2026 for askwhen.me's custom-domain tier.
#
# on_demand_tls: when a hostname nothing below names arrives in a handshake,
# ASK the askwhen service before ordering a certificate. The service says yes
# only for a hostname a paying owner has claimed and — for names outside its
# own zone — whose CNAME has been observed pointing here. Everything else is a
# refusal, and a refusal is cached. It fails closed: if the service is down,
# nothing is issued. interval/burst is Caddy's own throttle on top of that, so
# even a bug in the gate cannot spend more than five orders per two minutes
# of the rate-limit budget that renews every other site on this proxy.
#
# The key is in the URL because Caddy's ask sends no headers; the service also
# refuses the request from any address but this one, or with any X-Forwarded-*
# header, so the URL is the belt and the perimeter is the braces.
{{
	on_demand_tls {{
		ask http://172.16.1.41:8080/internal/tls-authorize?key={KEY}
		interval 2m
		burst 5
	}}
}}

"""
CATCHALL = """
# askwhen.me custom domains and subdomains. ENABLED 10 Sept 2026.
#
# Last, so it matches only hostnames nothing above claims. Every certificate
# issued here was authorised by the on_demand_tls ask in the global options —
# see the comment there, and askwhen/infra/edge.md in the cal-mirror repo.
# Customers CNAME at edge.askwhen.me; *.askwhen.me is a wildcard A record.
https:// {
	tls {
		on_demand
	}
	reverse_proxy http://172.16.1.41:8080
}
"""
open(P, "w").write(GLOBAL + src.rstrip("\n") + "\n" + CATCHALL)
print("written; backup at", P + ".bak-" + datetime.date.today().isoformat() + "-step6")
