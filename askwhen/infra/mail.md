# Mail — the failure that looks like nobody wanting to meet you

> **Read [`verified.md`](verified.md) first.** As of 2 Sept 2026 the live DNS
> says two steps here are already done, and that `rehosted.us`'s own SPF record
> contains a self-referential include which evaluates to `permerror`. This
> document was written without either fact.

**If confirmation emails land in spam, the product does not work, and nothing
tells you.** There is no error, no bounce, no support ticket. A requester picks
a slot, types their address, sees "check your email", and never confirms —
because the mail is in a folder they will not open. The request is swept after
an hour (§10). The owner is never disturbed, which is exactly what the design
promises when things are working. From inside the system a total delivery
failure and a quiet week are the same picture.

That is why `../README.md` says SPF, DKIM and DMARC must be right **before the
first confirmation email**, and why this document exists ahead of the service
that will send them.

The second reason is subtler: double opt-in is the entire spam defence (§8).
Every other measure — the honeypot, the per-IP limit — is a speed bump. If mail
delivery is unreliable then the defence that matters is also the thing standing
between honest people and the product, and the temptation to weaken it will be
immediate and wrong.

---

## The shape of it

```
app host                    mail host                     recipient
64.111.22.172               64.111.22.174
─────────────               ─────────────                 ─────────
service
  │
  ├── SMTP submission ────▶ postfix
  │   :587, STARTTLS,         │
  │   AUTH, one account       ├── opendkim signs d=askwhen.me s=aw1
  │                           │
  │                           └── delivers direct to MX ──▶ SPF: ip4 matches
  │                                                          DKIM: signature verifies
  │                                                          DMARC: both align on askwhen.me
```

Mail leaves from `dlvr.rehosted.us` but is *identified* as `askwhen.me`. That is
the arrangement worth being precise about, because the three mechanisms check
three different domains and it is easy to satisfy two of them and fail the one
that matters:

| Mechanism | Checks | Ours |
|---|---|---|
| SPF | the **envelope** sender's domain (`MAIL FROM`), and separately the HELO name | `bounces@askwhen.me` → `askwhen.me`'s SPF; HELO `dlvr.rehosted.us` → its own |
| DKIM | the `d=` in the signature | `d=askwhen.me` |
| DMARC | the **`From:` header** domain, and requires SPF or DKIM to *align* with it | `From: no-reply@askwhen.me` — aligns with both |

The alternative — `From: no-reply@dlvr.rehosted.us` — would pass every check and
still be worse, because the requester would receive a confirmation link for
`askwhen.me` from a domain they have never heard of. A stranger being asked to
click a link in mail from an unfamiliar host is being trained to do the wrong
thing, and a good number of them will simply not.

### Why the private key lives on the mail host and not the app host

The service submits authenticated mail and never signs it. So the app container
— the one exposed to the internet, parsing untrusted input from a public form —
holds an SMTP password that can send mail, and nothing that can *forge* it. A
compromise there costs the ability to send; it does not cost the domain's
signing identity, which is the expensive thing to rotate and the one receivers
remember.

---

## Generating the DKIM key

**Do this by hand on `dlvr.rehosted.us`. No key is generated, stored, or
committed by anything in this repository, and the `.gitignore` refuses the paths
where one could land.**

```sh
# On dlvr.rehosted.us, as root.
install -d -m 700 -o opendkim -g opendkim /etc/opendkim/keys/askwhen.me
cd /etc/opendkim/keys/askwhen.me

openssl genrsa -out aw1.private 2048
openssl rsa -in aw1.private -pubout -outform PEM -out aw1.public
chown opendkim:opendkim aw1.private
chmod 600 aw1.private
```

RSA 2048 rather than Ed25519. Ed25519 signatures are smaller and better, and a
meaningful share of receivers still cannot verify them — a signature nobody
checks is worse than a boring one everybody does. 2048 rather than 4096 because
some DNS providers still choke on the resulting TXT record length and the
failure mode is a silently unverifiable signature.

Then turn the public key into the record value:

```sh
# Everything between the PEM header and footer, on one line.
echo "v=DKIM1; k=rsa; p=$(sed '1d;$d' aw1.public | tr -d '\n')"
```

Paste that as the value of `aw1._domainkey.askwhen.me` (see `dns.md`). The
private half never leaves that directory.

### Rotation

The selector is `aw1` so that `aw2` can be published, signed with, and verified
before `aw1` is withdrawn. Rotate by publishing the new selector, waiting for
propagation, switching OpenDKIM's selector, watching a week of DMARC reports,
and only then deleting the old TXT record. **Deleting the old selector before
the last message signed with it has been delivered is irreversible** — those
messages become permanently unverifiable, and DMARC-enforcing receivers will act
on that.

---

## The DMARC path, which is a schedule and not a flag

Start at `p=none`. It changes nothing about how mail is treated; it only asks
receivers to send reports. Those reports are the only instrument available for
telling whether the two records above are actually working at Gmail's end
rather than in `dig`.

| Step | Record | Move on when |
|---|---|---|
| 1 | `v=DMARC1; p=none; rua=mailto:dmarc@askwhen.me; fo=1` | Two weeks of aggregate reports show 100% of askwhen.me mail passing DKIM **and** SPF with alignment, across at least Google and Microsoft. |
| 2 | `v=DMARC1; p=quarantine; pct=25; rua=mailto:dmarc@askwhen.me; fo=1` | A week at 25% with no drop in confirmation-click rate. |
| 3 | `v=DMARC1; p=quarantine; rua=mailto:dmarc@askwhen.me; fo=1` | Steady state. This is a fine place to stop. |
| 4 | `v=DMARC1; p=reject; adkim=s; aspf=s; rua=mailto:dmarc@askwhen.me; fo=1` | Only if there is a reason. `reject` protects a brand strangers do not have opinions about yet, and it turns any future misconfiguration from "in spam" into "does not arrive at all". |

Do not skip to step 3 because the `dig` output looks right. The thing being
measured is not whether the records parse; it is whether every path that sends
as askwhen.me is signing — and the path you forgot is the one that breaks when
enforcement turns on.

**If the `rua` address is ever moved off askwhen.me** — to `dmarc@rehosted.us`,
say — DMARC requires the receiving domain to publish permission for it:

    askwhen.me._report._dmarc.rehosted.us.  TXT  "v=DMARC1"

Without that record, conforming receivers silently stop sending reports. This is
one of the few places where the standard's failure mode is total silence, so it
is worth keeping `rua` on askwhen.me and avoiding the question entirely.

---

## Host configuration on dlvr — a sketch, not a deployment

Nothing here is applied by `deploy.py`. `deploy.py` runs on the app host and has
no route to the mail host, on purpose.

Postfix as a submission endpoint for exactly one account, with OpenDKIM as a
milter:

```
# /etc/postfix/main.cf — the parts that matter
myhostname = dlvr.rehosted.us
smtpd_tls_security_level = may
smtpd_sasl_auth_enable = yes                  # submission only, see master.cf
smtpd_relay_restrictions = permit_sasl_authenticated, reject
milter_default_action = reject                # unsigned mail must not go out
smtpd_milters = inet:127.0.0.1:8891
non_smtpd_milters = inet:127.0.0.1:8891
```

`milter_default_action = reject` is the important line. The default is `tempfail`
in some builds and `accept` in others, and `accept` means that when OpenDKIM is
down, mail goes out unsigned — which under a `p=quarantine` policy is worse than
not going out at all.

```
# /etc/opendkim.conf
Domain      askwhen.me
Selector    aw1
KeyFile     /etc/opendkim/keys/askwhen.me/aw1.private
Canonicalization relaxed/simple
```

Submission (587) is reachable from `64.111.22.172` and nowhere else. The app
host authenticates as one account whose password is the `smtp_password` secret;
that account may relay and may do nothing else.

---

## Verifying, before a real requester ever does it for you

Run all of these before the service sends its first confirmation.

```sh
# The records exist and say what you think.
dig +short TXT askwhen.me
dig +short TXT aw1._domainkey.askwhen.me
dig +short TXT _dmarc.askwhen.me
dig +short MX  askwhen.me

# Forward-confirmed reverse DNS, both directions.
dig +short -x 64.111.22.174
dig +short dlvr.rehosted.us

# An end-to-end message with the real headers.
swaks --server dlvr.rehosted.us:587 --tls --auth \
      --from bounces@askwhen.me --h-From 'askwhen.me <no-reply@askwhen.me>' \
      --to <a mail-tester.com address>
```

Then the two that actually decide it:

1. **mail-tester.com** — send it a message and read the whole report. Anything
   below 9/10 is worth understanding before shipping.
2. **A real Gmail account and a real Outlook account.** Send a message that looks
   like the confirmation email — same subject, same single link, same body — and
   use *Show original* / *View message source*. You are looking for three words:
   `spf=pass`, `dkim=pass`, `dmarc=pass`. Then check which folder it landed in,
   which is the question none of the other tools answer.

Do the Gmail and Outlook checks again after the first week of real traffic. A
new sending IP has no reputation, and the first hundred messages are where it is
decided.
