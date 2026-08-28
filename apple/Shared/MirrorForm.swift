import SwiftUI
import CalMirrorKit

/// The presets the projection editor offers; `custom` is "none of the above".
/// Aliased onto the kit's definition so the editor and the summary strings can
/// never disagree about what counts as a preset.
typealias Preset = MirrorSummary.Preset

func presetOf(_ p: Projection) -> Preset { MirrorSummary.preset(of: p) }

func applyPreset(_ preset: Preset, to p: inout Projection) {
    switch preset {
    case .details: p.title = .copy;   p.location = true;  p.notes = .none; p.alarms = false; p.availability = .source
    case .full:    p.title = .copy;   p.location = true;  p.notes = .full; p.alarms = false; p.availability = .source
    case .busy:    p.title = .redact; p.location = false; p.notes = .none; p.alarms = false; p.availability = .busy
    case .custom:  break   // reveal the controls, keep current values
    }
}

// The editor is split into four groups rather than one flat run of rows, because
// the two platforms place them differently: iPhone pushes each group onto its own
// screen, the Mac shows them as collapsible sections in one pane. Each group emits
// bare form rows (no Section wrapper) so the caller owns the container.

// MARK: - Pair

/// Name, source and destination — plus the reverse-direction guard, which lives
/// here so both platforms refuse a looping pair the same way.
struct PairFields: View {
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

// MARK: - What crosses over

/// How much of each source event reaches the copy.
struct ProjectionFields: View {
    @Binding var mirror: Mirror
    let onChange: () -> Void

    var body: some View {
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
            TextField("Title prefix", text: $mirror.projection.titlePrefix)
                .onChange(of: mirror.projection.titlePrefix) { _, _ in onChange() }
            Text("Prepended to the copy's title, e.g. “[Work]”. Applies even when the title is redacted.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Redact title", isOn: Binding(
                get: { mirror.projection.title == .redact },
                set: { mirror.projection.title = $0 ? .redact : .copy; onChange() }))
            Toggle("Copy location", isOn: $mirror.projection.location)
                .onChange(of: mirror.projection.location) { _, _ in onChange() }
            Picker("Notes", selection: $mirror.projection.notes) {
                Text("Don't copy").tag(NotesMode.none)
                Text("Tags only").tag(NotesMode.tags)
                Text("Full notes").tag(NotesMode.full)
            }
            .onChange(of: mirror.projection.notes) { _, _ in onChange() }
            if mirror.projection.notes == .tags {
                Text("Copies just the #tags onto the event, not the note text.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Copy alarms", isOn: $mirror.projection.alarms)
                .onChange(of: mirror.projection.alarms) { _, _ in onChange() }
            Toggle("Always show as busy", isOn: Binding(
                get: { mirror.projection.availability == .busy },
                set: { mirror.projection.availability = $0 ? .busy : .source; onChange() }))
        }
    }
}

// MARK: - Which events

/// Selection: the property filters first (they work on any calendar), then the
/// notes-tag rule (which only works on events you author), then the control-tag
/// legend. All three answer the same question, so they live on one screen.
struct SelectionFields: View {
    @Binding var mirror: Mirror
    let onChange: () -> Void

    var body: some View {
        Section("Skip events that are") {
            skipToggle("Declined by me", \.declined)
            skipToggle("Unanswered", \.unanswered)
            skipToggle("Canceled", \.canceled)
            skipToggle("All-day", \.allDay)
            skipToggle("Marked free", \.free)
        }

        Section("Duration") {
            minutesRow("Shorter than", \.shorterThanMinutes)
            minutesRow("Longer than", \.longerThanMinutes)
        }

        Section("Time of day") {
            Toggle("Limit by time", isOn: Binding(
                get: { mirror.filters.hours != nil },
                set: { on in
                    mirror.filters.hours = on
                        ? .init(mode: .keep, startMinute: 8 * 60, endMinute: 18 * 60, days: [2, 3, 4, 5, 6])
                        : nil
                    onChange()
                }))
            if mirror.filters.hours != nil {
                Picker("Rule", selection: hoursMode) {
                    Text("Only during").tag(EventFilters.HoursRule.Mode.keep)
                    Text("Except during").tag(EventFilters.HoursRule.Mode.drop)
                }
                DatePicker("From", selection: time(\.startMinute), displayedComponents: .hourAndMinute)
                DatePicker("To", selection: time(\.endMinute), displayedComponents: .hourAndMinute)
                DayPicker(days: days, onChange: onChange)
                Text("An event counts as inside the window if any part of it overlaps. All-day events are never matched here — use the all-day switch above.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        Section("Title") {
            Picker("Rule", selection: titleMode) {
                Text("Any title").tag("off")
                Text("Only if it contains…").tag("include")
                Text("Except if it contains…").tag("reject")
            }
            if mirror.filters.title != nil {
                TextField("Lunch, Focus time", text: titlePatterns)
                Text("Comma-separated, case-insensitive. Matches anywhere in the title.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        Section("By notes tag") {
            // Only works on events you author — the property filters above are
            // what a calendar you don't control responds to.
            Picker("Copy which events", selection: tagMode) {
                Text("All events").tag("off")
                Text("Only with tag…").tag("include")
                Text("Except with tag…").tag("reject")
            }
            if let f = mirror.tagFilter {
                TextField(f.mode == .include ? "Include tags" : "Reject tags", text: tagText)
                Text(f.mode == .include
                     ? "Copy an event only if its notes contain one of these tags."
                     : "Skip an event if its notes contain one of these tags.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Space-separated, e.g.  #ref #cowork").font(.caption).foregroundStyle(.secondary)
            }

            // Only meaningful when the whole note crosses over: in .tags the tags
            // are the payload, in .none there are no notes to strip.
            if mirror.projection.notes == .full {
                Toggle("Keep #tags in copied notes", isOn: $mirror.copyNotesTags)
                    .onChange(of: mirror.copyNotesTags) { _, _ in onChange() }
                Text("Off = strip #tags from the copied note. #+tag is always kept, #-tag always dropped.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Set “What to copy” → Notes to carry #tags onto the copy.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        Section("Control tags") {
            Text("Type into a source event's notes:").font(.caption).foregroundStyle(.secondary)
            Text("#nomirror — skip this event entirely").font(.caption)
            Text("#private — copy as a busy block").font(.caption)
            Text("#public — copy in full").font(.caption)
        }
    }

    // MARK: Bindings

    private func skipToggle(_ label: String, _ key: WritableKeyPath<EventFilters, Bool>) -> some View {
        Toggle(label, isOn: Binding(
            get: { mirror.filters[keyPath: key] },
            set: { mirror.filters[keyPath: key] = $0; onChange() }))
    }

    /// A minutes bound plus its on/off switch: 0 means the rule is off, so the
    /// stepper only appears once you've turned it on.
    private func minutesRow(_ label: String, _ key: WritableKeyPath<EventFilters, Int>) -> some View {
        let value = mirror.filters[keyPath: key]
        return Group {
            Toggle(label, isOn: Binding(
                get: { value > 0 },
                set: { mirror.filters[keyPath: key] = $0 ? 15 : 0; onChange() }))
            if value > 0 {
                Stepper("\(value) minutes", value: Binding(
                    get: { mirror.filters[keyPath: key] },
                    set: { mirror.filters[keyPath: key] = max(1, $0); onChange() }),
                    in: 1...(24 * 60), step: 5)
            }
        }
    }

    private var hoursMode: Binding<EventFilters.HoursRule.Mode> {
        Binding(get: { mirror.filters.hours?.mode ?? .keep },
                set: { mirror.filters.hours?.mode = $0; onChange() })
    }

    private var days: Binding<[Int]> {
        Binding(get: { mirror.filters.hours?.days ?? [] },
                set: { mirror.filters.hours?.days = $0; onChange() })
    }

    /// DatePicker speaks Date, the config stores minutes-from-midnight. Anchor on
    /// a fixed reference day so only the time component is ever read back.
    private func time(_ key: WritableKeyPath<EventFilters.HoursRule, Int>) -> Binding<Date> {
        Binding(
            get: {
                let mins = mirror.filters.hours?[keyPath: key] ?? 0
                return Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(mins) * 60)
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                mirror.filters.hours?[keyPath: key] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                onChange()
            })
    }

    private var titleMode: Binding<String> {
        Binding(
            get: { mirror.filters.title?.mode.rawValue ?? "off" },
            set: { v in
                let existing = mirror.filters.title?.patterns ?? []
                switch v {
                case "include": mirror.filters.title = .init(mode: .include, patterns: existing)
                case "reject":  mirror.filters.title = .init(mode: .reject, patterns: existing)
                default:        mirror.filters.title = nil
                }
                onChange()
            })
    }

    private var titlePatterns: Binding<String> {
        Binding(
            get: { mirror.filters.title?.patterns.joined(separator: ", ") ?? "" },
            set: { s in
                let parts = s.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty }
                mirror.filters.title = .init(mode: mirror.filters.title?.mode ?? .reject, patterns: parts)
                onChange()
            })
    }

    private var tagMode: Binding<String> {
        Binding(
            get: { mirror.tagFilter?.mode.rawValue ?? "off" },
            set: { v in
                let existing = mirror.tagFilter?.tags ?? []
                switch v {
                case "include": mirror.tagFilter = TagFilter(mode: .include, tags: existing)
                case "reject":  mirror.tagFilter = TagFilter(mode: .reject, tags: existing)
                default:        mirror.tagFilter = nil
                }
                onChange()
            })
    }

    private var tagText: Binding<String> {
        Binding(
            get: { mirror.tagFilter?.tags.joined(separator: " ") ?? "" },
            set: { s in
                let tags = s.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" }).map(String.init)
                mirror.tagFilter = TagFilter(mode: mirror.tagFilter?.mode ?? .include, tags: tags)
                onChange()
            })
    }
}

/// Weekday chips for the hours rule. Empty selection means every day, which is
/// what an hours window with no day restriction already meant.
struct DayPicker: View {
    @Binding var days: [Int]
    let onChange: () -> Void

    private let labels = [(1, "S"), (2, "M"), (3, "T"), (4, "W"), (5, "T"), (6, "F"), (7, "S")]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(labels, id: \.0) { num, label in
                let on = days.isEmpty || days.contains(num)
                Button {
                    var set = days.isEmpty ? Array(1...7) : days
                    if set.contains(num) { set.removeAll { $0 == num } } else { set.append(num) }
                    days = set.sorted()
                    onChange()
                } label: {
                    Text(label)
                        .font(.caption)
                        .frame(width: 26, height: 26)
                        .background(on ? Color.accentColor : Color.secondary.opacity(0.15))
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityLabel("Days the time window applies")
    }
}

// MARK: - Advanced

/// Heartbeat and the rolling sync window — the settings you set once and forget.
struct AdvancedFields: View {
    @Binding var mirror: Mirror
    let onChange: () -> Void

    var body: some View {
        Toggle("Heartbeat banner", isOn: $mirror.showHeartbeat)
            .onChange(of: mirror.showHeartbeat) { _, _ in onChange() }
        Stepper("History window: \(Int(mirror.windowPastDays)) days",
                value: $mirror.windowPastDays, in: 1...3650, step: 5)
            .onChange(of: mirror.windowPastDays) { _, _ in onChange() }
        Stepper("Future window: \(Int(mirror.windowFutureDays)) days",
                value: $mirror.windowFutureDays, in: 1...3650, step: 30)
            .onChange(of: mirror.windowFutureDays) { _, _ in onChange() }
    }
}

// MARK: - Compatibility

/// The original flat editor, kept so a caller that wants every row in one place
/// (the App Store Mac app's single-pane form) needn't restructure.
struct MirrorFields: View {
    @Binding var mirror: Mirror
    let calendars: [CalendarInfo]
    let reverseConflict: (CalRef, CalRef) -> Mirror?
    let onChange: () -> Void

    var body: some View {
        PairFields(mirror: $mirror, calendars: calendars,
                   reverseConflict: reverseConflict, onChange: onChange)
        ProjectionFields(mirror: $mirror, onChange: onChange)
        AdvancedFields(mirror: $mirror, onChange: onChange)
    }
}
