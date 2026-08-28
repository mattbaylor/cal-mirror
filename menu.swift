// CalMirrorMenu — menu-bar UI for cal-mirror.
// Shows per-mirror health, offers Sync now / Pause / interval, and a management
// window to add/edit mirror pairs with pickers over your Mac calendars.
// Reads calendars via EventKit (read-only), reads status.json, writes config.json.

import SwiftUI
import AppKit

let SUPPORT = ("~/.local/cal-mirror" as NSString).expandingTildeInPath
let ENGINE_LABEL = "io.github.mattbaylor.cal-mirror"

struct CalInfo: Hashable, Identifiable {
    var title: String, account: String, identifier: String, writable: Bool
    var id: String { identifier }
    var label: String { "\(title) — \(account)" }
}

struct MirrorStatus { var ok = false; var error: String?; var created = 0, updated = 0, unchanged = 0, deleted = 0, total = 0 }

final class Model: ObservableObject {
    // The kit's own types — same Config, same Mirror, same EventFilters the
    // engine reads. This app used to keep a parallel struct plus a hand-rolled
    // JSON writer, which meant every new config key had to be added twice and
    // any key this side didn't know about was dropped on the next save.
    @Published var mirrors: [Mirror] = []
    @Published var paused = false
    @Published var intervalSeconds = 900
    @Published var statuses: [String: MirrorStatus] = [:]
    @Published var lastRun: Date?
    @Published var calendars: [CalInfo] = []
    @Published var calendarAccess = false

    private var timer: Timer?
    private var configURL: URL { URL(fileURLWithPath: SUPPORT + "/config.json") }

    init() {
        loadCalendars()
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.loadCalendars(); self?.loadStatus()
        }
    }

    // Calendars come from calendars.json, published by the engine (which holds
    // Calendar access). The UI never touches EventKit, so it needs no TCC grant.
    func loadCalendars() {
        // Runs on the 5s timer; only reassign the @Published properties when the
        // parsed list actually changed, so we don't re-render the whole window
        // (and its pickers) every tick.
        let newList: [CalInfo]
        if let d = FileManager.default.contents(atPath: SUPPORT + "/calendars.json"),
           let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] {
            newList = arr.compactMap { o -> CalInfo? in
                guard let t = o["title"] as? String, let a = o["account"] as? String,
                      let id = o["identifier"] as? String else { return nil }
                return CalInfo(title: t, account: a, identifier: id, writable: o["writable"] as? Bool ?? false)
            }.sorted { ($0.account, $0.title) < ($1.account, $1.title) }
        } else {
            newList = []
        }
        if newList != calendars { calendars = newList }
        let access = !newList.isEmpty
        if access != calendarAccess { calendarAccess = access }
    }

    private func json(_ name: String) -> [String: Any]? {
        guard let d = FileManager.default.contents(atPath: SUPPORT + "/" + name) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    func reload() { loadConfig(); loadStatus() }

    // Mirror list + settings come from config.json. Loaded at startup and after
    // our own writes — deliberately NOT on the refresh timer, so a background
    // reload can never clobber an in-progress edit (e.g. typing a name) or steal
    // focus from the field being edited.
    func loadConfig() {
        // A missing file leaves the current state alone rather than blanking the
        // list: ConfigStore.load returns .empty for anything it can't read.
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        let cfg = ConfigStore.load(from: configURL)
        paused = cfg.paused
        intervalSeconds = cfg.intervalSeconds
        mirrors = cfg.mirrors
    }

    func loadStatus() {
        guard let o = json("status.json") else { return }
        if let v = o["lastRun"] as? String { lastRun = ISO8601DateFormatter().date(from: v) }
        var map: [String: MirrorStatus] = [:]
        for r in (o["mirrors"] as? [[String: Any]] ?? []) {
            guard let id = r["id"] as? String else { continue }
            var s = MirrorStatus()
            s.ok = r["ok"] as? Bool ?? false
            s.error = r["error"] as? String
            s.created = r["created"] as? Int ?? 0
            s.updated = r["updated"] as? Int ?? 0
            s.unchanged = r["unchanged"] as? Int ?? 0
            s.deleted = r["deleted"] as? Int ?? 0
            s.total = r["total"] as? Int ?? 0
            map[id] = s
        }
        statuses = map
    }

    // ---- Health ----
    func iconFor(_ id: String) -> String {
        if paused { return "pause.circle" }
        guard let s = statuses[id] else { return "questionmark.circle" }
        if let e = s.error, !e.isEmpty { return e == "disabled" ? "minus.circle" : "xmark.octagon.fill" }
        if !s.ok { return "xmark.octagon.fill" }
        if let last = lastRun, Date().timeIntervalSince(last) > Double(intervalSeconds) * 2 + 120 {
            return "exclamationmark.triangle.fill"
        }
        return "checkmark.circle.fill"
    }
    // What the menu-bar icon shows. Rows inside the menu keep their SF Symbols
    // (iconFor) — a face next to a line of text reads worse than a checkmark.
    #if os(macOS)
    var menuBarState: MenuBarState {
        if paused { return .paused }
        let enabled = mirrors.filter { $0.enabled }
        if enabled.isEmpty { return .unconfigured }
        let icons = enabled.map { iconFor($0.id) }
        if icons.contains("xmark.octagon.fill") { return .failing }
        // Stale and never-run both fold into degraded: either way the mirror is
        // not known to be current.
        if icons.contains("exclamationmark.triangle.fill") { return .degraded }
        if icons.contains("questionmark.circle") { return .degraded }
        return .ok
    }
    #endif
    var headline: String {
        if paused { return "Paused" }
        guard let last = lastRun else { return "No sync yet" }
        let rel = RelativeDateTimeFormatter(); rel.unitsStyle = .short
        return "Last sync \(rel.localizedString(for: last, relativeTo: Date()))"
    }

    // ---- Config persistence ----
    func saveConfig() {
        let cfg = Config(paused: paused, intervalSeconds: intervalSeconds, mirrors: mirrors)
        try? ConfigStore.save(cfg, to: configURL)
    }

    // A unique mirror id. The old timestamp-second scheme collided when two
    // mirrors were added within the same second, making them share a marker tag.
    func freshMirrorId() -> String {
        func gen() -> String { "m\(UUID().uuidString.prefix(12))" }
        var id = gen()
        while mirrors.contains(where: { $0.id == id }) { id = gen() }
        return id
    }

    // Reverse-direction guard: does (source -> dest) reverse some other mirror
    // that goes dest -> source? Returns that mirror if so (config would loop).
    func calId(_ ref: CalRef) -> String? {
        if let a = ref.account, let c = calendars.first(where: { $0.title == ref.title && $0.account == a }) {
            return c.identifier
        }
        return calendars.first { $0.title == ref.title }?.identifier
    }
    func reverseConflict(source: CalRef, dest: CalRef, excluding id: String) -> Mirror? {
        guard let s = calId(source), let d = calId(dest) else { return nil }
        return mirrors.first { m in
            m.id != id && calId(m.source) == d && calId(m.dest) == s
        }
    }

    /// Mirrors bucketed by destination, in first-appearance order so the list
    /// doesn't reshuffle while you edit. Values index into `mirrors`, so each row
    /// still binds to the real element.
    var destinationGroups: [(name: String, indices: [Int])] {
        var order: [String] = []
        var buckets: [String: [Int]] = [:]
        for (i, m) in mirrors.enumerated() {
            let name = m.dest.title.isEmpty ? "No destination" : m.dest.title
            if buckets[name] == nil { order.append(name) }
            buckets[name, default: []].append(i)
        }
        return order.map { (name: $0, indices: buckets[$0] ?? []) }
    }

    // ---- Shell actions ----
    @discardableResult
    private func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        do { try p.run() } catch { return -1 }
        p.waitUntilExit(); return p.terminationStatus
    }
    private var domain: String { "gui/\(getuid())/\(ENGINE_LABEL)" }

    func syncNow() {
        run("/bin/launchctl", ["kickstart", "-k", domain])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.reload() }
    }
    func togglePause() { paused.toggle(); saveConfig(); reload() }
    func toggleEnabled(_ id: String) {
        if let i = mirrors.firstIndex(where: { $0.id == id }) { mirrors[i].enabled.toggle(); saveConfig() }
    }
    func toggleHeartbeat(_ id: String) {
        if let i = mirrors.firstIndex(where: { $0.id == id }) { mirrors[i].showHeartbeat.toggle(); saveConfig() }
    }
    // The engine re-reads config.json each cycle, so saving is enough to change
    // the interval — but it would not take effect until the current sleep (up to
    // an hour) ends. Restart the daemon so the new interval applies now.
    func setInterval(_ secs: Int) {
        intervalSeconds = secs; saveConfig()
        run("/bin/launchctl", ["bootout", domain])
        run("/bin/launchctl", ["bootstrap", "gui/\(getuid())",
                               "\(NSHomeDirectory())/Library/LaunchAgents/\(ENGINE_LABEL).plist"])
    }
    func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: SUPPORT + "/mirror.log")) }
    func openCalendarApp() { run("/usr/bin/open", ["-a", "Calendar"]) }
}

// ---- Menu ----------------------------------------------------------------
struct MenuContent: View {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow
    private let intervals: [(String, Int)] = [("5 min", 300), ("15 min", 900), ("30 min", 1800), ("1 hour", 3600)]

    var body: some View {
        Text("cal-mirror — \(model.headline)")
        if model.mirrors.isEmpty {
            Text("No mirrors configured").font(.caption)
        }
        ForEach(model.mirrors) { m in
            let s = model.statuses[m.id]
            Menu("\(symbol(model.iconFor(m.id)))  \(m.name)") {
                if let s = s, let e = s.error, !e.isEmpty { Text("⚠︎ \(e)") }
                else if let s = s { Text("\(s.total) events  (+\(s.created) ~\(s.updated) −\(s.deleted))") }
                Text("\(m.source.title)  →  \(m.dest.title)").font(.caption)
                Divider()
                Toggle("Enabled", isOn: Binding(get: { m.enabled }, set: { _ in model.toggleEnabled(m.id) }))
                Toggle("Heartbeat banner", isOn: Binding(get: { m.showHeartbeat }, set: { _ in model.toggleHeartbeat(m.id) }))
            }
        }
        Divider()
        Button(model.paused ? "Resume syncing" : "Sync now") {
            if model.paused { model.togglePause() } else { model.syncNow() }
        }
        Button("Pause syncing") { model.togglePause() }.disabled(model.paused)
        Menu("Sync interval") {
            ForEach(intervals, id: \.1) { name, secs in
                Button(name + (model.intervalSeconds == secs ? "  ✓" : "")) { model.setInterval(secs) }
            }
        }
        Divider()
        Button("Manage mirrors…") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "manage")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Open Calendar") { model.openCalendarApp() }
        Button("Open log") { model.openLog() }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
    private func symbol(_ n: String) -> String {
        switch n {
        case "checkmark.circle.fill": return "✓"
        case "exclamationmark.triangle.fill": return "⚠︎"
        case "xmark.octagon.fill": return "✗"
        case "pause.circle": return "⏸"
        case "minus.circle": return "∅"
        default: return "•"
        }
    }
}

// ---- Management window ----------------------------------------------------
// Master–detail, not one long form. The old layout rendered every control of
// every mirror at once: ten mirrors was a ~2,000pt scroll in which the two that
// were actually configured differently looked exactly like the eight that
// weren't. One mirror at a time, grouped by destination, with each section
// collapsed to a line that says what it's set to.
struct ManageView: View {
    @ObservedObject var model: Model
    @State private var selection: String?
    @FocusState private var focusedName: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(model.destinationGroups, id: \.name) { group in
                    Section("\(group.name)  ·  \(group.indices.count)") {
                        ForEach(group.indices, id: \.self) { i in
                            SidebarRow(model: model, mirror: model.mirrors[i])
                                .tag(model.mirrors[i].id)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button {
                        let new = Mirror(id: model.freshMirrorId(), name: "New mirror",
                                         source: CalRef(title: ""), dest: CalRef(title: ""))
                        model.mirrors.append(new)
                        model.saveConfig()
                        selection = new.id
                        focusedName = new.id
                    } label: { Label("Add mirror", systemImage: "plus") }
                    Spacer()
                }
                .padding(8)
                .background(.bar)
            }
        } detail: {
            if let idx = selectedIndex {
                MirrorDetail(model: model, m: $model.mirrors[idx], focusedName: $focusedName,
                             onRemove: { removeSelected() })
                    .id(model.mirrors[idx].id)
            } else {
                ContentUnavailableView("No mirror selected",
                                       systemImage: "arrow.left.arrow.right",
                                       description: Text("Pick a mirror on the left, or add one."))
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .onAppear {
            if selection == nil { selection = model.mirrors.first?.id }
        }
        .overlay(alignment: .top) {
            if !model.calendarAccess {
                VStack(spacing: 6) {
                    Text("No calendars detected yet — run a sync so the engine can list them for the pickers.")
                        .foregroundStyle(.orange)
                    Button("Sync now") { model.syncNow() }
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 8)
            }
        }
        // Drop back to a menu-bar-only (no Dock, no app menu) app when the
        // management window closes. It only becomes a regular app while open.
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    private var selectedIndex: Int? {
        guard let selection else { return nil }
        return model.mirrors.firstIndex { $0.id == selection }
    }

    private func removeSelected() {
        guard let id = selection else { return }
        let idx = model.mirrors.firstIndex { $0.id == id }
        model.mirrors.removeAll { $0.id == id }
        model.saveConfig()
        // Select the neighbour that took its place, so the detail pane isn't
        // left empty after every removal.
        if let idx { selection = model.mirrors.indices.contains(idx) ? model.mirrors[idx].id
                                 : model.mirrors.last?.id }
        else { selection = model.mirrors.first?.id }
    }
}

/// One row in the sidebar: health, name, source, and a delta line naming only
/// what diverges from a plain copy-everything mirror. The destination is the
/// section header, so the row needn't repeat it.
struct SidebarRow: View {
    @ObservedObject var model: Model
    let mirror: Mirror

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: model.iconFor(mirror.id))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(mirror.name.isEmpty ? "Untitled" : mirror.name)
                    .lineLimit(1)
                Text(mirror.source.title.isEmpty ? "— no source —" : mirror.source.title)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let delta = MirrorSummary.delta(mirror) {
                    Text(delta).font(.caption).foregroundStyle(.tint).lineLimit(1)
                }
            }
            Spacer()
            if let s = model.statuses[mirror.id], s.error == nil {
                Text("\(s.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var tint: Color {
        switch model.iconFor(mirror.id) {
        case "checkmark.circle.fill": return .green
        case "exclamationmark.triangle.fill": return .orange
        case "xmark.octagon.fill": return .red
        default: return .secondary
        }
    }
}

// ---- Detail pane ----------------------------------------------------------

/// One mirror's settings. The pair is always visible; everything else collapses
/// to a header line that says what it's set to, so the pane stays short enough
/// to read even with the filters expanded.
struct MirrorDetail: View {
    @ObservedObject var model: Model
    @Binding var m: Mirror
    @FocusState.Binding var focusedName: String?
    let onRemove: () -> Void

    @State private var conflict: String?
    @State private var showProjection = false
    @State private var showSelection = false
    @State private var showAdvanced = false

    var body: some View {
        Form {
            Section("Pair") {
                TextField("Name", text: $m.name)
                    .focused($focusedName, equals: m.id)
                    .onChange(of: m.name) { _, _ in model.saveConfig() }
                Picker("Source", selection: pick(isSource: true)) {
                    Text("— choose —").tag("")
                    ForEach(model.calendars) { c in Text(c.label).tag(c.identifier) }
                }
                Picker("Destination", selection: pick(isSource: false)) {
                    Text("— choose —").tag("")
                    ForEach(model.calendars.filter { $0.writable }) { c in Text(c.label).tag(c.identifier) }
                }
                if let conflict {
                    Label(conflict, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                Toggle("Enabled", isOn: $m.enabled).onChange(of: m.enabled) { _, _ in model.saveConfig() }
            }

            Section {
                DisclosureGroup(isExpanded: $showProjection) {
                    ProjectionEditor(m: $m, onChange: { model.saveConfig() })
                } label: {
                    SummaryLabel(title: "What crosses over", trailing: nil,
                                 detail: MirrorSummary.projection(m.projection))
                }
            }

            Section {
                DisclosureGroup(isExpanded: $showSelection) {
                    SelectionEditor(m: $m, onChange: { model.saveConfig() })
                } label: {
                    SummaryLabel(title: "Which events", trailing: ruleCountLabel,
                                 detail: MirrorSummary.selection(m.filters, tagFilter: m.tagFilter))
                }
            }

            Section {
                DisclosureGroup(isExpanded: $showAdvanced) {
                    Toggle("Heartbeat banner", isOn: $m.showHeartbeat)
                        .onChange(of: m.showHeartbeat) { _, _ in model.saveConfig() }
                    Stepper("History window: \(Int(m.windowPastDays)) days",
                            value: $m.windowPastDays, in: 1...3650, step: 5)
                        .onChange(of: m.windowPastDays) { _, _ in model.saveConfig() }
                    Stepper("Future window: \(Int(m.windowFutureDays)) days",
                            value: $m.windowFutureDays, in: 1...3650, step: 30)
                        .onChange(of: m.windowFutureDays) { _, _ in model.saveConfig() }
                    if let ls = m.legacyScheme {
                        Text("Migrating legacy tags (\(ls))").font(.caption).foregroundStyle(.secondary)
                    }
                } label: {
                    SummaryLabel(title: "Advanced", trailing: nil, detail: MirrorSummary.advanced(m))
                }
            }

            Section {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove mirror", systemImage: "trash")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(m.name.isEmpty ? "Mirror" : m.name)
    }

    private var ruleCountLabel: String? {
        var n = m.filters.activeRuleCount
        if m.tagFilter?.isActive == true { n += 1 }
        guard n > 0 else { return nil }
        return n == 1 ? "1 rule" : "\(n) rules"
    }

    private func pick(isSource: Bool) -> Binding<String> {
        Binding(
            get: { model.calId(isSource ? m.source : m.dest) ?? "" },
            set: { newId in
                guard let c = model.calendars.first(where: { $0.identifier == newId }) else { return }
                let ref = CalRef(title: c.title, account: c.account)
                let newSource = isSource ? ref : m.source
                let newDest = isSource ? m.dest : ref
                if let clash = model.reverseConflict(source: newSource, dest: newDest, excluding: m.id) {
                    conflict = "Can’t reverse “\(clash.name)” — the copy would loop back."
                    return   // reject the change
                }
                conflict = nil
                if isSource { m.source = ref } else { m.dest = ref }
                model.saveConfig()
            })
    }
}

/// A disclosure header that names a section and says what it's currently set to,
/// so the collapsed state still carries the answer.
struct SummaryLabel: View {
    let title: String
    let trailing: String?
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title)
                if let trailing {
                    Spacer()
                    Text(trailing).foregroundStyle(.secondary)
                }
            }
            if let detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// How much of each source event reaches the copy.
struct ProjectionEditor: View {
    @Binding var m: Mirror
    let onChange: () -> Void

    var body: some View {
        // "Custom" can't be derived from the fields (it's the absence of a preset
        // match), so the explicit choice is persisted in projection.custom.
        Picker("What to copy", selection: Binding(
            get: { m.projection.custom ? .custom : MirrorSummary.preset(of: m.projection) },
            set: { p in
                if p == .custom { m.projection.custom = true }
                else { m.projection.custom = false; applyPreset(p, to: &m.projection) }
                onChange()
            })) {
            Text("Copy details").tag(MirrorSummary.Preset.details)
            Text("Full copy").tag(MirrorSummary.Preset.full)
            Text("Busy only").tag(MirrorSummary.Preset.busy)
            Text("Custom").tag(MirrorSummary.Preset.custom)
        }
        if m.projection.title == .redact {
            TextField("Shown as", text: $m.projection.titleText)
                .onChange(of: m.projection.titleText) { _, _ in onChange() }
        }
        if m.projection.custom || MirrorSummary.preset(of: m.projection) == .custom {
            Toggle("Redact title", isOn: Binding(
                get: { m.projection.title == .redact },
                set: { m.projection.title = $0 ? .redact : .copy; onChange() }))
            Toggle("Copy location", isOn: $m.projection.location)
                .onChange(of: m.projection.location) { _, _ in onChange() }
            Picker("Notes", selection: $m.projection.notes) {
                Text("Don't copy").tag(NotesMode.none)
                Text("Tags only").tag(NotesMode.tags)
                Text("Full notes").tag(NotesMode.full)
            }
            .onChange(of: m.projection.notes) { _, _ in onChange() }
            if m.projection.notes == .tags {
                Text("Copies just the #tags onto the event, not the note text.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Copy alarms", isOn: $m.projection.alarms)
                .onChange(of: m.projection.alarms) { _, _ in onChange() }
            Toggle("Always show as busy", isOn: Binding(
                get: { m.projection.availability == .busy },
                set: { m.projection.availability = $0 ? .busy : .source; onChange() }))
        }
    }
}

func applyPreset(_ preset: MirrorSummary.Preset, to p: inout Projection) {
    switch preset {
    case .details: p.title = .copy;   p.location = true;  p.notes = .none; p.alarms = false; p.availability = .source
    case .full:    p.title = .copy;   p.location = true;  p.notes = .full; p.alarms = false; p.availability = .source
    case .busy:    p.title = .redact; p.location = false; p.notes = .none; p.alarms = false; p.availability = .busy
    case .custom:  break   // reveal the controls, keep current values
    }
}

/// Which events are copied: property filters first (they work on any calendar),
/// then the notes-tag rule (which only works on events you author), then the
/// control-tag legend. All three answer the same question.
struct SelectionEditor: View {
    @Binding var m: Mirror
    let onChange: () -> Void

    var body: some View {
        GroupBox("Skip events that are") {
            VStack(alignment: .leading, spacing: 4) {
                skipToggle("Declined by me", \.declined)
                skipToggle("Unanswered", \.unanswered)
                skipToggle("Canceled", \.canceled)
                skipToggle("All-day", \.allDay)
                skipToggle("Marked free", \.free)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }

        GroupBox("Duration") {
            VStack(alignment: .leading, spacing: 4) {
                minutesRow("Shorter than", \.shorterThanMinutes)
                minutesRow("Longer than", \.longerThanMinutes)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }

        GroupBox("Time of day") {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Limit by time", isOn: Binding(
                    get: { m.filters.hours != nil },
                    set: { on in
                        m.filters.hours = on
                            ? .init(mode: .keep, startMinute: 8 * 60, endMinute: 18 * 60, days: [2, 3, 4, 5, 6])
                            : nil
                        onChange()
                    }))
                if m.filters.hours != nil {
                    Picker("Rule", selection: Binding(
                        get: { m.filters.hours?.mode ?? .keep },
                        set: { m.filters.hours?.mode = $0; onChange() })) {
                        Text("Only during").tag(EventFilters.HoursRule.Mode.keep)
                        Text("Except during").tag(EventFilters.HoursRule.Mode.drop)
                    }
                    DatePicker("From", selection: time(\.startMinute), displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: time(\.endMinute), displayedComponents: .hourAndMinute)
                    DayChips(days: Binding(
                        get: { m.filters.hours?.days ?? [] },
                        set: { m.filters.hours?.days = $0; onChange() }))
                    Text("An event counts as inside the window if any part of it overlaps. All-day events are never matched here — use the all-day switch above.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }

        GroupBox("Title") {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Rule", selection: titleMode) {
                    Text("Any title").tag("off")
                    Text("Only if it contains…").tag("include")
                    Text("Except if it contains…").tag("reject")
                }
                if m.filters.title != nil {
                    TextField("Lunch, Focus time", text: titlePatterns)
                    Text("Comma-separated, case-insensitive. Matches anywhere in the title.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }

        GroupBox("By notes tag") {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Copy which events", selection: tagMode) {
                    Text("All events").tag("off")
                    Text("Only with tag…").tag("include")
                    Text("Except with tag…").tag("reject")
                }
                if let f = m.tagFilter {
                    TextField(f.mode == .include ? "Include tags" : "Reject tags", text: tagText)
                    Text(f.mode == .include
                         ? "Copy an event only if its notes contain one of these tags."
                         : "Skip an event if its notes contain one of these tags.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Space-separated, e.g.  #ref #cowork").font(.caption).foregroundStyle(.secondary)
                }
                // Only meaningful when the whole note crosses over: in .tags the
                // tags are the payload, in .none there are no notes to strip.
                if m.projection.notes == .full {
                    Toggle("Keep #tags in copied notes", isOn: $m.copyNotesTags)
                        .onChange(of: m.copyNotesTags) { _, _ in onChange() }
                    Text("Off = strip #tags from the copied note. #+tag is always kept, #-tag always dropped.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Set “What crosses over” → Notes to carry #tags onto the copy.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }

        GroupBox("Control tags — type into a source event's notes") {
            VStack(alignment: .leading, spacing: 2) {
                Text("#nomirror — skip this event entirely").font(.caption)
                Text("#private — copy as a busy block").font(.caption)
                Text("#public — copy in full").font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    // MARK: Bindings

    private func skipToggle(_ label: String, _ key: WritableKeyPath<EventFilters, Bool>) -> some View {
        Toggle(label, isOn: Binding(
            get: { m.filters[keyPath: key] },
            set: { m.filters[keyPath: key] = $0; onChange() }))
    }

    /// A minutes bound plus its on/off switch: 0 means the rule is off, so the
    /// stepper only appears once you've turned it on.
    private func minutesRow(_ label: String, _ key: WritableKeyPath<EventFilters, Int>) -> some View {
        let value = m.filters[keyPath: key]
        return Group {
            Toggle(label, isOn: Binding(
                get: { value > 0 },
                set: { m.filters[keyPath: key] = $0 ? 15 : 0; onChange() }))
            if value > 0 {
                Stepper("\(value) minutes", value: Binding(
                    get: { m.filters[keyPath: key] },
                    set: { m.filters[keyPath: key] = max(1, $0); onChange() }),
                    in: 1...(24 * 60), step: 5)
            }
        }
    }

    /// DatePicker speaks Date, the config stores minutes-from-midnight. Anchor on
    /// a fixed reference day so only the time component is ever read back.
    private func time(_ key: WritableKeyPath<EventFilters.HoursRule, Int>) -> Binding<Date> {
        Binding(
            get: {
                let mins = m.filters.hours?[keyPath: key] ?? 0
                return Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(mins) * 60)
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                m.filters.hours?[keyPath: key] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                onChange()
            })
    }

    private var titleMode: Binding<String> {
        Binding(
            get: { m.filters.title?.mode.rawValue ?? "off" },
            set: { v in
                let existing = m.filters.title?.patterns ?? []
                switch v {
                case "include": m.filters.title = .init(mode: .include, patterns: existing)
                case "reject":  m.filters.title = .init(mode: .reject, patterns: existing)
                default:        m.filters.title = nil
                }
                onChange()
            })
    }

    private var titlePatterns: Binding<String> {
        Binding(
            get: { m.filters.title?.patterns.joined(separator: ", ") ?? "" },
            set: { s in
                let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                m.filters.title = .init(mode: m.filters.title?.mode ?? .reject, patterns: parts)
                onChange()
            })
    }

    private var tagMode: Binding<String> {
        Binding(
            get: { m.tagFilter?.mode.rawValue ?? "off" },
            set: { v in
                let existing = m.tagFilter?.tags ?? []
                switch v {
                case "include": m.tagFilter = TagFilter(mode: .include, tags: existing)
                case "reject":  m.tagFilter = TagFilter(mode: .reject, tags: existing)
                default:        m.tagFilter = nil
                }
                onChange()
            })
    }

    private var tagText: Binding<String> {
        Binding(
            get: { m.tagFilter?.tags.joined(separator: " ") ?? "" },
            set: { s in
                let tags = s.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" }).map(String.init)
                m.tagFilter = TagFilter(mode: m.tagFilter?.mode ?? .include, tags: tags)
                onChange()
            })
    }
}

/// Weekday chips for the hours rule. Empty selection means every day, which is
/// what an hours window with no day restriction already meant.
struct DayChips: View {
    @Binding var days: [Int]
    private let labels = [(1, "S"), (2, "M"), (3, "T"), (4, "W"), (5, "T"), (6, "F"), (7, "S")]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(labels, id: \.0) { num, label in
                let on = days.isEmpty || days.contains(num)
                Button {
                    var set = days.isEmpty ? Array(1...7) : days
                    if set.contains(num) { set.removeAll { $0 == num } } else { set.append(num) }
                    days = set.sorted()
                } label: {
                    Text(label)
                        .font(.caption)
                        .frame(width: 22, height: 22)
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

// The menu-bar icon is the only entrance to this app, and macOS clips extras
// when the bar runs out of room — a clipped icon locks you out of the Manage
// window completely. This delegate is the way back in:
//
//   open -a CalMirrorMenu            # app already running — the normal case,
//                                    # since launchd KeepAlive owns it
//   open -a CalMirrorMenu --args --manage   # cold launch only
//
// Both paths exist because LaunchServices forwards --args only to a cold
// launch; for a running instance it sends a reopen event instead and drops the
// arguments on the floor.
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Set by the scene below, which is what owns openWindow.
    static var showManage: (() -> Void)?

    func applicationDidFinishLaunching(_: Notification) {
        guard CommandLine.arguments.contains("--manage") else { return }
        // Let the scene finish building before asking it for a window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Self.showManage?() }
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        Self.showManage?()
        return true
    }
}

@main
struct CalMirrorMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = Model()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Hand the delegate a way in: it has no scene of its own, and this
        // capture does not depend on the icon ever being drawn.
        let _ = (AppDelegate.showManage = showManage)
        MenuBarExtra { MenuContent(model: model) } label: { Image(nsImage: menuBarImage(model.menuBarState)) }
            .menuBarExtraStyle(.menu)
        Window("Manage Mirrors", id: "manage") { ManageView(model: model) }
    }

    // Same three steps the menu's "Manage mirrors…" button takes.
    private func showManage() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "manage")
        NSApp.activate(ignoringOtherApps: true)
    }
}
