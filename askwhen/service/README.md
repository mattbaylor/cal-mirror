# askwhen.me — service

The dead drop. Slots in, requests out, and no idea who the owner is.

Endpoints, stored state and the request lifecycle: `../design/architecture.md` §4.

Nothing here yet, and deliberately built **last** — it is the least interesting
part and the easiest to change. Steps 1 and 2 are provable without it.

Blocked on decisions 6 (lapse behaviour), 9 (email provider — the one remaining
third party in the design) and 11 (where it runs).

The test that matters: after a full publish → request → confirm → resolve cycle,
dump the stored records and confirm they contain no owner email, no owner name
beyond the public display label, no calendar data and no credential. If that ever
fails, the product's claim is false.
