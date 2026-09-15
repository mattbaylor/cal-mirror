import SwiftUI
import CalMirrorKit

/// Screen 3 — *which calendars count*, asked where the owner is already looking
/// at their calendars (`decisions.md`, "Which calendars count — explicit, in
/// Manage Mirrors"). Two checkboxes per calendar, writing straight to
/// `RequestPageConfig.blocking` and `.requestCalendar`.
///
/// **Use for requests is exactly one calendar**, so it behaves as a radio rather
/// than a checkbox even though it is drawn as one: turning it on somewhere else
/// turns it off here. A multi-select would be a config the Kit cannot honor —
/// `accept` writes into a single `CalRef` — and the place to make that
/// impossible is the control, not a validation message afterwards.
///
/// The privacy caption is not decoration. `MirrorEngine.busyIntervals` is where
/// title, location, attendees, calendar and account stop, and this is the only
/// screen where the owner hands over a calendar, so it is the one place that
/// sentence is load-bearing.
struct RequestCalendarFields: View {
    @Binding var page: RequestPageConfig
    let calendars: [CalendarInfo]
    let onChange: () -> Void

    var body: some View {
        Section(RequestCopy.Calendars.section) {
            if calendars.isEmpty {
                Text("No calendars yet — grant Calendar access and they will appear here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(calendars) { cal in
                CalendarRequestRow(
                    calendar: cal,
                    blocking: blockingBinding(cal),
                    isRequestCalendar: requestBinding(cal))
            }

            Text(RequestCopy.Calendars.blockCaption)
                .font(.caption).foregroundStyle(.secondary)
            Text(RequestCopy.Calendars.useCaption)
                .font(.caption).foregroundStyle(.secondary)

            // Shown only when it is actionable. A standing warning that is
            // always on screen stops being read, and both of these describe a
            // page that would behave wrongly if published as it stands.
            if page.blocking.isEmpty {
                Label(RequestCopy.Calendars.noneBlocking, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if page.requestCalendar == nil {
                Label(RequestCopy.Calendars.noRequestCalendar, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            Text(RequestCopy.Calendars.privacy)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Bindings

    /// `CalRef` carries the account so two calendars both called "Home" from
    /// different accounts stay distinct — the same pairing `PairFields` uses.
    private func ref(_ c: CalendarInfo) -> CalRef { CalRef(title: c.title, account: c.account) }

    private func blockingBinding(_ c: CalendarInfo) -> Binding<Bool> {
        Binding(
            get: { page.blocking.contains(ref(c)) },
            set: { on in
                let r = ref(c)
                if on {
                    guard !page.blocking.contains(r) else { return }
                    page.blocking.append(r)
                } else {
                    page.blocking.removeAll { $0 == r }
                }
                onChange()
            })
    }

    private func requestBinding(_ c: CalendarInfo) -> Binding<Bool> {
        Binding(
            get: { page.requestCalendar == ref(c) },
            set: { on in
                // Assigning replaces whatever held it, which is what "exactly
                // one" means; turning it off clears it and leaves the page
                // unpublishable until another is picked, which `isReady`
                // already enforces and the warning above already says.
                page.requestCalendar = on ? ref(c) : nil
                onChange()
            })
    }
}

/// One calendar's two checkboxes. Split out because the Mac shows both on one
/// line and the phone stacks them, and because a row that knows nothing about
/// the config is the one that can be previewed on its own.
struct CalendarRequestRow: View {
    let calendar: CalendarInfo
    @Binding var blocking: Bool
    @Binding var isRequestCalendar: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(calendar.label).lineLimit(1)
            #if os(macOS)
            HStack(spacing: 18) { checkboxes }
            #else
            // A switch is 31pt tall but a Toggle inside a row reports its
            // label's height, so two of them at spacing 2 draw on top of each
            // other. The minimum height makes each row as tall as its control.
            VStack(alignment: .leading, spacing: 4) { checkboxes }
            #endif
            // Only said on the calendars where it changes the answer, so it
            // reads as a reason this one is different rather than as noise.
            if !calendar.writable {
                Text(RequestCopy.Calendars.readOnly)
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    #if os(macOS)
    private let controlHeight: CGFloat? = nil
    #else
    private let controlHeight: CGFloat? = 31
    #endif

    @ViewBuilder private var checkboxes: some View {
        Toggle(RequestCopy.Calendars.blockTitle, isOn: $blocking)
            .frame(minHeight: controlHeight)
        Toggle(RequestCopy.Calendars.useTitle, isOn: $isRequestCalendar)
            // A calendar the app cannot write to cannot hold an accepted
            // request, so the choice is refused at the control rather than
            // failing later with `calendarReadOnly` when somebody says yes.
            .disabled(!calendar.writable)
            .frame(minHeight: controlHeight)
    }
}
