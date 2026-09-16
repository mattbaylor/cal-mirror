import SwiftUI
import CalMirrorKit

/// Screen 6 — the offers this policy makes against this calendar, on real dates,
/// before anyone else can see them.
///
/// `architecture.md` §3: *"the preview underneath shows real dates so a mistake
/// is visible before anyone else sees it."* It is also the only honest
/// demonstration the product has, which is why `decisions.md` puts it before
/// the offer screen rather than after.
///
/// **Local, always.** This runs `SlotDeriver` against the device's own
/// calendars and publishes nothing. Nothing on this screen may touch the
/// network — the app's first request of any kind is one screen further on.
struct RequestPreview: View {
    let page: RequestPageConfig
    /// Injected rather than reached for, so this view can be driven from a
    /// fixture with no EventKit and no calendars — which is how it gets
    /// screenshotted from a synthetic config rather than Matt's real one.
    let busy: (_ calendars: [CalRef], _ from: Date, _ to: Date) -> [BusyInterval]
    var now: Date = Date()

    var body: some View {
        // The count is the large-number moment on this screen and the only
        // large text on it (native.md, §6); the screen's title is its header.
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(count).font(.largeTitle.weight(.bold))
                Text(across).font(.body).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            if let problem = diagnosis.policyProblem {
                Label(RequestCopy.Preview.reason(problem), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            } else if slots.isEmpty {
                Text(RequestCopy.Preview.emptyPage)
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(offeredDays, id: \.day) { day in
                    DayOfferRow(label: label(for: day.day), slots: slotsOn(day.day), zone: zone)
                }
            }
        } footer: {
            // "Why is Thursday empty" is answered by the section below when
            // there is one; when every day offers something, the gap line
            // still belongs here, because it is about the gaps within a day.
            Text(emptyDays.isEmpty ? RequestCopy.Preview.stale + " " + RequestCopy.Preview.privacy
                                   : RequestCopy.Preview.stale)
        }

        // Only the days that offered nothing, because "why is Thursday empty"
        // is the question people actually ask — and the only one a settings
        // screen cannot answer, since the answer is an interaction between the
        // policy and the contents of a calendar.
        if !emptyDays.isEmpty {
            Section {
                ForEach(emptyDays, id: \.day) { day in
                    LabeledContent(label(for: day.day)) {
                        Text(explanation(day)).multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                Text(RequestCopy.Preview.emptyDayHeading)
            } footer: {
                let capped = emptyDays.contains { ($0.rejections[.cappedPerDay] ?? 0) > 0 }
                Text(capped ? RequestCopy.Preview.privacy + " " + RequestCopy.Preview.cappedNote
                            : RequestCopy.Preview.privacy)
            }
        }
    }

    // MARK: Derivation

    /// One day past the horizon, matching what `RequestPageCoordinator` asks
    /// for, so the preview and the thing that actually publishes cannot answer
    /// differently.
    private var window: (from: Date, to: Date) {
        (now.addingTimeInterval(-86400),
         now.addingTimeInterval(TimeInterval(page.policy.horizonDays + 1) * 86400))
    }
    private var intervals: [BusyInterval] { busy(page.blocking, window.from, window.to) }
    private var slots: [Slot] { SlotDeriver.derive(policy: page.policy, busy: intervals, now: now) }
    private var diagnosis: Diagnosis {
        SlotDeriver.explain(policy: page.policy, busy: intervals, now: now)
    }

    private var offeredDays: [DayDiagnosis] { diagnosis.days.filter { $0.offered > 0 } }
    /// `emptyDays` from the Kit includes days excluded outright; both belong
    /// here, since "I do not work Sundays" and "I was busy all day" are equally
    /// good answers to why nothing showed.
    private var emptyDays: [DayDiagnosis] { diagnosis.emptyDays }

    private var zone: TimeZone { page.policy.resolvedTimeZone ?? .current }

    private var count: String {
        let n = slots.count
        return String(format: n == 1 ? RequestCopy.Preview.countOne : RequestCopy.Preview.countMany, n)
    }
    private var across: String {
        String(format: RequestCopy.Preview.across, page.policy.horizonDays)
    }

    /// The day key is `yyyy-MM-dd` in the owner's zone; turn it back into
    /// something readable without re-deriving the date arithmetic.
    private func label(for key: String) -> String {
        let parse = DateFormatter()
        parse.calendar = Calendar(identifier: .gregorian)
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.timeZone = zone
        parse.dateFormat = "yyyy-MM-dd"
        guard let d = parse.date(from: key) else { return key }
        let show = DateFormatter()
        show.timeZone = zone
        show.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return show.string(from: d)
    }

    private func slotsOn(_ key: String) -> [Slot] {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd"
        // Chronological, never wall-clock: on the day a clock falls back,
        // sorting by local time interleaves the two passes through the repeated
        // hour and offers 1:00, 1:00, 1:30, 1:30. decisions.md, "Slot order is
        // chronological, never wall-clock." `derive` already returns them in
        // instant order, so filtering preserves it.
        return slots.filter { f.string(from: $0.start) == key }
    }

    /// "6 busy, 2 over your daily cap" — counts and nothing else. `Rejection`
    /// carries no event, title or calendar by design, so there is nothing here
    /// that could leak what the owner was doing.
    private func explanation(_ day: DayDiagnosis) -> String {
        if let whole = day.dayRejection { return RequestCopy.Preview.reason(whole) }
        let parts = day.orderedRejections.map { "\($0.1) \(RequestCopy.Preview.reason($0.0))" }
        return parts.isEmpty ? "" : parts.joined(separator: ", ")
    }
}

/// One day's offers as chips. Times carry their zone abbreviation on any day
/// where a clock change makes two of them collide — `decisions.md`, "The hour
/// that happens twice — qualify the whole day" — so "1:30 AM" appearing twice
/// reads as a distinction rather than a bug.
struct DayOfferRow: View {
    let label: String
    let slots: [Slot]
    let zone: TimeZone

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Text(slots.map(time(_:)).joined(separator: "   "))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// True when two of the day's offers render to the same local label, which
    /// happens only on a fall-back day. Qualifying just the colliding pair was
    /// tried and reads as an oversight, so the whole day is qualified or none
    /// of it is.
    private var ambiguous: Bool {
        let plain = slots.map { plainTime($0.start) }
        return Set(plain).count != plain.count
    }

    private func time(_ s: Slot) -> String {
        ambiguous ? "\(plainTime(s.start)) \(abbreviation(at: s.start))" : plainTime(s.start)
    }

    private func plainTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeZone = zone
        f.setLocalizedDateFormatFromTemplate("j:mm")
        return f.string(from: d)
    }

    private func abbreviation(at d: Date) -> String {
        zone.abbreviation(for: d) ?? ""
    }
}
