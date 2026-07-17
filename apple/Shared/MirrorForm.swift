import SwiftUI
import CalMirrorKit

/// The presets the projection editor offers; Custom is "none of the above".
enum Preset: Hashable { case details, full, busy, custom }

func presetOf(_ p: Projection) -> Preset {
    let redact = p.title == .redact, busy = p.availability == .busy
    if !redact && p.location && !p.notes && !p.alarms && !busy { return .details }
    if !redact && p.location && p.notes && !p.alarms && !busy { return .full }
    if redact && !p.location && !p.notes && !p.alarms && busy { return .busy }
    return .custom
}
func applyPreset(_ preset: Preset, to p: inout Projection) {
    switch preset {
    case .details: p.title = .copy;   p.location = true;  p.notes = false; p.alarms = false; p.availability = .source
    case .full:    p.title = .copy;   p.location = true;  p.notes = true;  p.alarms = false; p.availability = .source
    case .busy:    p.title = .redact; p.location = false; p.notes = false; p.alarms = false; p.availability = .busy
    case .custom:  break   // reveal the controls, keep current values
    }
}

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

        // "Custom" can't be derived from the fields (it's the absence of a preset
        // match), so the explicit choice is persisted in projection.custom.
        Picker("What to copy", selection: Binding(
            get: { mirror.projection.custom ? .custom : presetOf(mirror.projection) },
            set: { p in
                if p == .custom { mirror.projection.custom = true }
                else { mirror.projection.custom = false; applyPreset(p, to: &mirror.projection) }
                onChange()
            })) {
            Text("Copy details").tag(Preset.details)
            Text("Full copy").tag(Preset.full)
            Text("Busy only").tag(Preset.busy)
            Text("Custom").tag(Preset.custom)
        }
        if mirror.projection.title == .redact {
            TextField("Shown as", text: $mirror.projection.titleText)
                .onChange(of: mirror.projection.titleText) { _, _ in onChange() }
        }
        if mirror.projection.custom || presetOf(mirror.projection) == .custom {
            Toggle("Redact title", isOn: Binding(
                get: { mirror.projection.title == .redact },
                set: { mirror.projection.title = $0 ? .redact : .copy; onChange() }))
            Toggle("Copy location", isOn: $mirror.projection.location)
                .onChange(of: mirror.projection.location) { _, _ in onChange() }
            Toggle("Copy notes", isOn: $mirror.projection.notes)
                .onChange(of: mirror.projection.notes) { _, _ in onChange() }
            Toggle("Copy alarms", isOn: $mirror.projection.alarms)
                .onChange(of: mirror.projection.alarms) { _, _ in onChange() }
            Toggle("Always show as busy", isOn: Binding(
                get: { mirror.projection.availability == .busy },
                set: { mirror.projection.availability = $0 ? .busy : .source; onChange() }))
        }
        DisclosureGroup("Per-event tags") {
            VStack(alignment: .leading, spacing: 3) {
                Text("Type into a source event's title:").font(.caption).foregroundStyle(.secondary)
                Text("#nomirror — skip this event entirely").font(.caption)
                Text("#private — copy as a busy block").font(.caption)
                Text("#public — copy in full").font(.caption)
            }
        }

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
