import Foundation
import CalMirrorKit

/// The one place "Send times" is put together from the device: the policy
/// and blocking calendars the request page uses (or the defaults, for an
/// owner who never set one up), the busy shape from the engine, the deriver,
/// and the composer. The app's row, the Mac menu item and the intent all call
/// this, so they cannot offer different times.
///
/// No service. The link at the end is the page's address if there is one,
/// and nothing about this reaches the network — which is why it belongs in
/// Calendar Mirror rather than behind the subscription (`decisions.md`,
/// *"Send times"*).
enum SendTimesSource {
    static let count = 3

    /// Nil when there is nothing to offer inside the horizon.
    static func text(config: Config, engine: CalendarAccess, calendars: [CalendarInfo],
                     now: Date = Date(), locale: Locale = .current) -> String? {
        let page = config.requestPage ?? RequestPageConfig()
        let policy = page.policy
        let zone = policy.resolvedTimeZone ?? .current
        // An owner who has not chosen blocking calendars is still busy when
        // their calendar says so. Writable calendars block; subscribed and
        // read-only ones (holidays, a sports feed) do not — the same
        // inference zero-decision setup will make.
        let blocking = page.blocking.isEmpty
            ? calendars.filter(\.writable).map { CalRef(title: $0.title, account: $0.account) }
            : page.blocking
        let to = now.addingTimeInterval(TimeInterval(policy.horizonDays + 1) * 86400)
        let busy = engine.busyIntervals(in: blocking, from: now.addingTimeInterval(-86400), to: to)
        let slots = SlotDeriver.derive(policy: policy, busy: busy, now: now)
        let picks = SendTimes.pick(slots, count: count, zone: zone)
        guard !picks.isEmpty else { return nil }
        let link = page.enabled && !page.slug.isEmpty ? "askwhen.me/\(page.slug)" : nil
        return SendTimes.text(picks, zone: zone, link: link, now: now, locale: locale)
    }
}
