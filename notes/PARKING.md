# Parking lot

Things noticed and deliberately not done now. Not a board: nothing here has an
owner or a date, and nothing here is blocking anything. When one gets picked up
it moves to [`TASKS.md`](TASKS.md); when it stops mattering it is deleted.
Add the date and the reason it was parked, so a later reader can tell whether
it still applies.

- **AskWhen.me's `maxPerDay` default of 4** (`apple/Sources/CalMirrorKit/Booking/RequestPolicy.swift`).
  Parked 17 Sept 2026 while rewriting the site: "a few times a day" is what the
  page promises, and 4 was picked without much thought. Revisit with a real page
  in use — is 4 too generous, too stingy, or should it scale with the horizon?

- **The AskWhen.me experience, brand and colours** across the app screens and
  the web request page. Matt's, in its own session (17 Sept 2026). The site's
  presentation of it (`docs/askwhen.html`) went first and should follow whatever
  that session decides.

- **`docs/img/menubar.png` has no dark variant**, so in dark mode it sits as a
  light card. Parked 17 Sept 2026: needs a re-shoot with the fixture, not a
  filter.

- **Eleven site images nothing references any more** — `docs/img/filters-*`,
  `iphone-detail-*` (the list is used, the detail is not in every mode),
  `state-*.png` (superseded by `face-*.png`). Parked 17 Sept 2026: the filters
  shots would suit a README section if that copy moves there; delete the rest.

- **The README has no Shortcuts / Siri section.** The site used to carry it;
  now only the release notes do. Parked 17 Sept 2026.

- **The changelog's `In review` pill on 2.0** is the one place the site still
  says so, because `watch-review.yml` keys on it to stamp the release date.
  Fine to leave; noted here in case the pill is ever read as marketing.
