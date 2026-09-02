# askwhen.me — service

The dead drop. Slots in, requests out, and no idea who the owner is.

Endpoints, stored state and the request lifecycle: `../design/architecture.md` §4.
Scaling and the one feature that must never be built: `../design/scale.md`.

Go 1.23, pure-Go SQLite (`modernc.org/sqlite`), `CGO_ENABLED=0` so the runtime
image can be distroless static — no shell, no package manager, nothing to exploit
if the request handler is ever wrong about untrusted input. See
`../infra/README.md` for why Go and why SQLite.

## What exists

Step 3 has not started. Two pieces were built ahead of it because both are
expensive or impossible to add later.

```
internal/tlsauth/    the gate in front of Caddy's on-demand TLS
internal/httpcache/  conditional GET for the two endpoints that carry the traffic
internal/store/      SQLite: the domain lookup, and the two validators
```

There is no `cmd/askwhen` yet, so the Dockerfile will not build. That is still
the contract those directories have to satisfy, not a defect.

```
go test -race ./...
```

## The wire contract, which cannot be changed later

**Both read endpoints are conditional, and the device client must send
`If-None-Match` from its very first release.**

This is the one decision in `scale.md` that is not deferrable. Cache semantics
cannot be retrofitted once devices ship: an old client keeps polling the way it
was built to poll for as long as somebody has not updated, and there is no way to
make it stop. Everything else about scaling this service can be decided late.

| Endpoint | Validator | Derived from |
|---|---|---|
| `GET /p/{slug}.json` | strong ETag | SHA-256 of the dump bytes (`page.dump_etag`) |
| `GET /v1/pages/{slug}/queue` | weak ETag | `page.queue_version`, a counter the triggers maintain |

Both answer **304** to a matching `If-None-Match`, and both send
`Cache-Control: no-cache` — which means *revalidate before using*, not *do not
store*. A dump served without revalidation would show slots that have since been
taken, and the design is honest about being a snapshot.

**Why the two validators differ.** The dump's is a content hash, so a device
that republishes byte-identical content does not invalidate every requester's
cache. The queue's is a counter, because the alternative — hashing the queue —
means reading the queue, and the whole point is that an empty poll should not
touch the `request` table at all. Device polling is O(owners) and almost always
returns nothing; it costs one primary-key lookup on `page`.

The queue's tag is **weak** because that is what we can honestly promise. Its
bytes are derived from a counter today, so a strong tag would also be true — but
the moment the payload carries a server timestamp or reorders, a strong tag
becomes a lie and nothing would notice.

`queue_version` is maintained by triggers rather than by code paths remembering,
because the failure mode of forgetting one is a device that never learns a
request arrived. Silent, and indistinguishable from nobody wanting to meet you.

## The test that matters, still unwritten

After a full publish → request → confirm → resolve cycle, dump the stored records
and confirm they contain no owner email, no owner name beyond the public display
label, no calendar data and no credential. If that ever fails, the product's
claim is false.
