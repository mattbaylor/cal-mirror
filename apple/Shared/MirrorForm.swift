import SwiftUI
import CalMirrorKit

/// Shared editor for one mirror's fields, used by both the iOS and macOS apps.
/// It emits form rows (no Section wrapper) so each platform can place them in
/// whatever Form/Section structure it prefers. The reverse-direction guard lives
/// here so both platforms block a source/dest choice that would loop.
struct MirrorFields: View {
    @Binding var mirror: Mirror
    let calendars: [CalendarInfo]
    /// Returns the mirror that a (source → dest) choice would reverse, if any.
    let reverseConflict: (CalRef, CalRef) -> Mirror?
    let onChange: () -> Void

    @State private var conflict: String?

    var body: some View {
        TextField("Name", text: $mirror.name).onSubmit(onChange)
        Picker("Source", selection: pick(isSource: true)) {
            Text("— choose —").tag("")
            ForEach(calendars) { c in Text(c.label).tag(c.identifier) }
        }
        Picker("Destination", selection: pick(isSource: false)) {
            Text("— choose —").tag("")
            ForEach(calendars.filter { $0.writable }) { c in Text(c.label).tag(c.identifier) }
        }
        if let conflict {
            Label(conflict, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        }
        Toggle("Heartbeat banner", isOn: $mirror.showHeartbeat)
            .onChange(of: mirror.showHeartbeat) { _, _ in onChange() }
        Stepper("History window: \(Int(mirror.windowPastDays)) days",
                value: $mirror.windowPastDays, in: 1...3650, step: 5)
            .onChange(of: mirror.windowPastDays) { _, _ in onChange() }
        Stepper("Future window: \(Int(mirror.windowFutureDays)) days",
                value: $mirror.windowFutureDays, in: 1...3650, step: 30)
            .onChange(of: mirror.windowFutureDays) { _, _ in onChange() }
    }

    private func calId(_ title: String, _ account: String?) -> String {
        if let a = account, let c = calendars.first(where: { $0.title == title && $0.account == a }) {
            return c.identifier
        }
        return calendars.first(where: { $0.title == title })?.identifier ?? ""
    }

    private func pick(isSource: Bool) -> Binding<String> {
        Binding(
            get: {
                isSource ? calId(mirror.source.title, mirror.source.account)
                         : calId(mirror.dest.title, mirror.dest.account)
            },
            set: { id in
                guard let c = calendars.first(where: { $0.identifier == id }) else { return }
                let newSource = isSource ? CalRef(title: c.title, account: c.account) : mirror.source
                let newDest   = isSource ? mirror.dest : CalRef(title: c.title, account: c.account)
                if let clash = reverseConflict(newSource, newDest) {
                    conflict = "Can’t reverse “\(clash.name)” — the copy would loop back."
                    return
                }
                conflict = nil
                if isSource { mirror.source = newSource } else { mirror.dest = newDest }
                onChange()
            })
    }
}
