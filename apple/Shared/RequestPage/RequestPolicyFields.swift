import SwiftUI
import CalMirrorKit

/// Screen 5 — the policy, asked the way `architecture.md` §3 says to ask it.
///
/// > Do not ask for "not before" and "not after" — that phrasing forces the
/// > owner to think in negatives and hides which timezone is meant. Ask for
/// > their day.
///
/// So the first group is a sentence with the values inline, and the zone is
/// stated **on the line** rather than inferred. Everything below it is a number
/// with its consequence written next to it, because most of these are privacy
/// settings wearing the clothes of preferences — `maxPerDay` and `horizonDays`
/// especially, and neither is obvious from its name.
struct RequestPolicyFields: View {
    @Binding var policy: RequestPolicy
    let onChange: () -> Void

    /// Only divisors of 60. A value that does not divide the hour still
    /// produces a consistent grid, but one that walks through it — :00, :25,
    /// :50, :15 — which reads as a bug to everyone who sees the page.
    static let alignChoices = [5, 10, 15, 20, 30, 60]
    static let slotChoices = [15, 20, 30, 45, 60, 90]
    static let bufferChoices = [0, 5, 10, 15, 30]
    static let noticeChoices = [0, 2, 4, 12, 24, 48]

    var body: some View {
        Section {
            // One sentence on the Mac, where it fits on a line. On a phone the
            // same line wraps mid-phrase ("My day / starts at"), so it breaks
            // at the clause instead: the two halves stay a sentence read top
            // to bottom, and each picker sits beside the words it belongs to.
            #if os(macOS)
            HStack(spacing: 6) {
                Text(RequestCopy.Policy.dayStarts)
                timeField(\.day.starts)
                Text(RequestCopy.Policy.dayEnds)
                timeField(\.day.ends)
            }
            .font(.body)
            #else
            HStack(spacing: 6) {
                Text(RequestCopy.Policy.dayStarts)
                Spacer()
                timeField(\.day.starts)
            }
            HStack(spacing: 6) {
                Text(RequestCopy.Policy.dayEnds)
                Spacer()
                timeField(\.day.ends)
            }
            #endif

            Picker(RequestCopy.Policy.zoneTitle, selection: Binding(
                get: { policy.timeZone },
                set: { policy.timeZone = $0; onChange() })) {
                ForEach(Self.zones, id: \.self) { Text($0).tag($0) }
            }
            // A Form's default picker on the phone is a pop-up menu, and 400
            // zones in a menu is a wall that cannot be searched or scrolled
            // to. Pushed as its own list it is at least a list.
            #if !os(macOS)
            .pickerStyle(.navigationLink)
            #endif
            Text(RequestCopy.Policy.zoneCaption)
                .font(.caption).foregroundStyle(.secondary)

            Toggle(RequestCopy.Policy.lunchTitle, isOn: Binding(
                get: { policy.lunch != nil },
                set: { policy.lunch = $0 ? RequestPolicy.Lunch() : nil; onChange() }))
            if policy.lunch != nil {
                HStack(spacing: 6) {
                    timeField(\.lunchFrom)
                    Text("to")
                    timeField(\.lunchTo)
                }
            }
            Text(RequestCopy.Policy.lunchCaption)
                .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text(RequestCopy.Policy.weekdaysTitle)
                WeekdayPicker(weekdays: Binding(
                    get: { policy.weekdays },
                    set: { policy.weekdays = $0; onChange() }))
            }
        } header: {
            Text(RequestCopy.Policy.section)
        } footer: {
            Text(RequestCopy.Policy.sentence)
        }

        Section {
            // Clamped by RequestPolicy's own setter, so the stepper's range and
            // the model agree by construction rather than by my remembering to
            // type the same two numbers twice.
            Stepper("\(RequestCopy.Policy.horizonTitle): \(policy.horizonDays) days",
                    value: Binding(get: { policy.horizonDays },
                                   set: { policy.horizonDays = $0; onChange() }),
                    in: RequestPolicy.horizonRange)
            caption(RequestCopy.Policy.horizonCaption)

            choice(RequestCopy.Policy.noticeTitle, Self.noticeChoices, \.minNoticeHours) {
                $0 == 0 ? "None" : "\($0) hours"
            }
            caption(RequestCopy.Policy.noticeCaption)

            Stepper("\(RequestCopy.Policy.maxPerDayTitle): \(policy.maxPerDay)",
                    value: Binding(get: { policy.maxPerDay },
                                   set: { policy.maxPerDay = max(1, $0); onChange() }),
                    in: 1...12)
            caption(RequestCopy.Policy.maxPerDayCaption)

            choice(RequestCopy.Policy.slotTitle, Self.slotChoices, \.slotMinutes) { "\($0) min" }
            caption(RequestCopy.Policy.slotCaption)

            choice(RequestCopy.Policy.alignTitle, Self.alignChoices, \.align) { Self.alignLabel($0) }
            caption(RequestCopy.Policy.alignCaption)

            choice(RequestCopy.Policy.bufferTitle, Self.bufferChoices, \.bufferMinutes) {
                $0 == 0 ? "Nothing" : "\($0) min"
            }
            caption(RequestCopy.Policy.bufferCaption)
        }
    }

    // MARK: Pieces

    private func caption(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary)
    }

    private func choice(_ title: String, _ options: [Int],
                        _ key: WritableKeyPath<RequestPolicy, Int>,
                        label: @escaping (Int) -> String) -> some View {
        Picker(title, selection: Binding(
            get: { policy[keyPath: key] },
            set: { policy[keyPath: key] = $0; onChange() })) {
            ForEach(options, id: \.self) { Text(label($0)).tag($0) }
        }
    }

    /// Shows what the grid actually produces rather than the raw number: "30"
    /// is a quantity, ":00 and :30" is the thing the owner is choosing between.
    static func alignLabel(_ minutes: Int) -> String {
        switch minutes {
        case 60: return ":00"
        case 30: return ":00 and :30"
        default:
            let marks = stride(from: 0, to: 60, by: minutes).map { String(format: ":%02d", $0) }
            return marks.joined(separator: " ")
        }
    }

    /// The policy stores wall-clock `HH:mm` strings on purpose — a rule that is
    /// meant to outlive today's UTC offset must not be stored as an instant —
    /// so the picker anchors on a fixed day and only the time is read back, the
    /// same trick `SelectionFields` uses for its hours rule.
    private func timeField(_ key: WritableKeyPath<RequestPolicy, String>) -> some View {
        DatePicker("", selection: Binding(
            get: {
                let mins = RequestPolicy.minutesPastMidnight(policy[keyPath: key]) ?? 0
                return Calendar.current.startOfDay(for: Date())
                    .addingTimeInterval(Double(mins) * 60)
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                policy[keyPath: key] = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
                onChange()
            }),
            displayedComponents: .hourAndMinute)
            .labelsHidden()
    }

    /// The device's own zone first, then the rest. A full IANA list in a picker
    /// is 400 rows deep and the right answer is nearly always at the top.
    static var zones: [String] {
        let here = TimeZone.current.identifier
        return [here] + TimeZone.knownTimeZoneIdentifiers.filter { $0 != here }
    }
}

/// `RequestPolicy.Lunch` is optional, and key paths cannot reach through an
/// optional to a stored property. These read as absent-safe accessors so the
/// time fields above can bind to them like any other `HH:mm`.
private extension RequestPolicy {
    var lunchFrom: String {
        get { lunch?.from ?? "12:00" }
        set { lunch = Lunch(from: newValue, to: lunch?.to ?? "13:30") }
    }
    var lunchTo: String {
        get { lunch?.to ?? "13:30" }
        set { lunch = Lunch(from: lunch?.from ?? "12:00", to: newValue) }
    }
}

/// Weekday chips. Deliberately not `DayPicker` from `MirrorForm`: that one
/// speaks `Calendar` numbers and treats empty as "every day", and this one
/// speaks `RequestPolicy.Weekday` where empty means a page that offers nothing.
/// Sharing them would make one of those two meanings wrong.
struct WeekdayPicker: View {
    @Binding var weekdays: [RequestPolicy.Weekday]

    private let order: [(RequestPolicy.Weekday, String)] = [
        (.sun, "S"), (.mon, "M"), (.tue, "T"), (.wed, "W"),
        (.thu, "T"), (.fri, "F"), (.sat, "S"),
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(order, id: \.0) { day, label in
                let on = weekdays.contains(day)
                Button {
                    if on { weekdays.removeAll { $0 == day } } else { weekdays.append(day) }
                    weekdays.sort { $0.calendarWeekday < $1.calendarWeekday }
                } label: {
                    Text(label)
                        .font(.caption)
                        .frame(width: 26, height: 26)
                        .background(on ? Color.accentColor : Color.secondary.opacity(0.15))
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(describing: day))
                .accessibilityValue(on ? "offered" : "not offered")
            }
        }
    }
}
