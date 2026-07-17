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

struct MirrorCfg: Identifiable, Equatable {
    var id: String
    var name: String
    var sourceTitle: String, sourceAccount: String
    var destTitle: String, destAccount: String
    var enabled: Bool
    var showHeartbeat: Bool
    var windowPastDays: Double
    var windowFutureDays: Double
    // Field projection — mirrors main.swift's Projection. Defaults reproduce the
    // historical behavior (real title + location, no notes/alarms, source busy).
    var projTitleRedact: Bool = false
    var projTitleText: String = "Busy"
    var projLocation: Bool = true
    var projNotes: Bool = false
    var projAlarms: Bool = false
    var projBusy: Bool = false
    var projCustom: Bool = false   // UI: user explicitly chose "Custom" (persisted so it sticks)
    var legacyScheme: String?
}

// The presets the editor offers; Custom is "none of the above".
enum Preset: Hashable { case details, full, busy, custom }
func presetOf(_ m: MirrorCfg) -> Preset {
    if !m.projTitleRedact && m.projLocation && !m.projNotes && !m.projAlarms && !m.projBusy { return .details }
    if !m.projTitleRedact && m.projLocation && m.projNotes && !m.projAlarms && !m.projBusy { return .full }
    if m.projTitleRedact && !m.projLocation && !m.projNotes && !m.projAlarms && m.projBusy { return .busy }
    return .custom
}
func applyPreset(_ p: Preset, to m: inout MirrorCfg) {
    switch p {
    case .details: m.projTitleRedact = false; m.projLocation = true;  m.projNotes = false; m.projAlarms = false; m.projBusy = false
    case .full:    m.projTitleRedact = false; m.projLocation = true;  m.projNotes = true;  m.projAlarms = false; m.projBusy = false
    case .busy:    m.projTitleRedact = true;  m.projLocation = false; m.projNotes = false; m.projAlarms = false; m.projBusy = true
    case .custom:  break   // reveal the controls, keep current values
    }
}

struct MirrorStatus { var ok = false; var error: String?; var created = 0, updated = 0, unchanged = 0, deleted = 0, total = 0 }

final class Model: ObservableObject {
    @Published var mirrors: [MirrorCfg] = []
    @Published var paused = false
    @Published var intervalSeconds = 900
    @Published var statuses: [String: MirrorStatus] = [:]
    @Published var lastRun: Date?
    @Published var calendars: [CalInfo] = []
    @Published var calendarAccess = false

    private var timer: Timer?

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
        guard let o = json("config.json") else { return }
        paused = o["paused"] as? Bool ?? false
        intervalSeconds = o["intervalSeconds"] as? Int ?? 900
        var list: [MirrorCfg] = []
        for m in (o["mirrors"] as? [[String: Any]] ?? []) {
            guard let id = m["id"] as? String,
                  let s = m["source"] as? [String: Any], let st = s["title"] as? String,
                  let d = m["dest"] as? [String: Any], let dt = d["title"] as? String else { continue }
            let pj = m["projection"] as? [String: Any] ?? [:]
            let titleText = (pj["titleText"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Busy"
            list.append(MirrorCfg(
                id: id, name: m["name"] as? String ?? id,
                sourceTitle: st, sourceAccount: s["account"] as? String ?? "",
                destTitle: dt, destAccount: d["account"] as? String ?? "",
                enabled: m["enabled"] as? Bool ?? true,
                showHeartbeat: m["showHeartbeat"] as? Bool ?? true,
                windowPastDays: m["windowPastDays"] as? Double ?? 30,
                windowFutureDays: m["windowFutureDays"] as? Double ?? 365,
                projTitleRedact: (pj["title"] as? String) == "redact",
                projTitleText: titleText,
                projLocation: pj["location"] as? Bool ?? true,
                projNotes: pj["notes"] as? Bool ?? false,
                projAlarms: pj["alarms"] as? Bool ?? false,
                projBusy: (pj["availability"] as? String) == "busy",
                projCustom: pj["custom"] as? Bool ?? false,
                legacyScheme: m["legacyScheme"] as? String))
        }
        mirrors = list
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
    var overallIcon: String {
        if paused { return "pause.circle" }
        if mirrors.isEmpty { return "circle.dashed" }
        let icons = mirrors.filter { $0.enabled }.map { iconFor($0.id) }
        if icons.contains("xmark.octagon.fill") { return "xmark.octagon.fill" }
        if icons.contains("exclamationmark.triangle.fill") { return "exclamationmark.triangle.fill" }
        if icons.contains("questionmark.circle") { return "questionmark.circle" }
        return "checkmark.circle.fill"
    }
    var headline: String {
        if paused { return "Paused" }
        guard let last = lastRun else { return "No sync yet" }
        let rel = RelativeDateTimeFormatter(); rel.unitsStyle = .short
        return "Last sync \(rel.localizedString(for: last, relativeTo: Date()))"
    }

    // ---- Config persistence ----
    func saveConfig() {
        var o = json("config.json") ?? [:]
        o["paused"] = paused
        o["intervalSeconds"] = intervalSeconds
        o["mirrors"] = mirrors.map { m -> [String: Any] in
            var d: [String: Any] = [
                "id": m.id, "name": m.name,
                "source": ["title": m.sourceTitle, "account": m.sourceAccount],
                "dest": ["title": m.destTitle, "account": m.destAccount],
                "enabled": m.enabled, "showHeartbeat": m.showHeartbeat,
                "windowPastDays": m.windowPastDays, "windowFutureDays": m.windowFutureDays,
                "projection": [
                    "title": m.projTitleRedact ? "redact" : "copy",
                    "titleText": m.projTitleText.isEmpty ? "Busy" : m.projTitleText,
                    "location": m.projLocation,
                    "notes": m.projNotes,
                    "alarms": m.projAlarms,
                    "availability": m.projBusy ? "busy" : "source",
                    "custom": m.projCustom,
                ],
            ]
            if let ls = m.legacyScheme { d["legacyScheme"] = ls }
            return d
        }
        if let data = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: SUPPORT + "/config.json"), options: .atomic)
        }
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
    func calId(_ title: String, _ account: String) -> String? {
        calendars.first { $0.title == title && $0.account == account }?.identifier
            ?? calendars.first { $0.title == title }?.identifier
    }
    func reverseConflict(sourceTitle: String, sourceAccount: String,
                         destTitle: String, destAccount: String, excluding id: String) -> MirrorCfg? {
        guard let s = calId(sourceTitle, sourceAccount), let d = calId(destTitle, destAccount) else { return nil }
        return mirrors.first { m in
            m.id != id
                && calId(m.sourceTitle, m.sourceAccount) == d
                && calId(m.destTitle, m.destAccount) == s
        }
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
    func setInterval(_ secs: Int) {
        intervalSeconds = secs; saveConfig()
        let plist = "\(NSHomeDirectory())/Library/LaunchAgents/\(ENGINE_LABEL).plist"
        run("/usr/libexec/PlistBuddy", ["-c", "Set :StartInterval \(secs)", plist])
        run("/bin/launchctl", ["bootout", domain])
        run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist])
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
                Text("\(m.sourceTitle)  →  \(m.destTitle)").font(.caption)
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
struct ManageView: View {
    @ObservedObject var model: Model
    // Which mirror's name field holds keyboard focus. Set on "Add mirror" so the
    // new row is focused and ready to rename.
    @FocusState private var focusedName: String?
    @State private var scrollTarget: String?

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    HStack {
                        Text("Mirror pairs").font(.headline)
                        Spacer()
                        Button {
                            let new = MirrorCfg(id: model.freshMirrorId(),
                                name: "New mirror", sourceTitle: "", sourceAccount: "",
                                destTitle: "", destAccount: "", enabled: true, showHeartbeat: true,
                                windowPastDays: 30, windowFutureDays: 365, legacyScheme: nil)
                            model.mirrors.append(new); model.saveConfig()
                            scrollTarget = new.id   // scroll to + focus it (below)
                        } label: { Label("Add mirror", systemImage: "plus") }
                    }
                    if !model.calendarAccess {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No calendars detected yet — run a sync so the engine can list them for the pickers.")
                                .foregroundStyle(.orange)
                            Button("Sync now") { model.syncNow() }
                        }
                    }
                    if model.mirrors.isEmpty {
                        Text("No mirrors yet. Click “Add mirror”.").foregroundStyle(.secondary)
                    }
                }
                ForEach($model.mirrors) { $m in
                    Section(header: Text($m.wrappedValue.name.isEmpty ? "Mirror" : $m.wrappedValue.name)) {
                        MirrorRow(model: model, m: $m, focusedName: $focusedName)
                    }
                    .id(m.id)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 640, minHeight: 480)
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                DispatchQueue.main.async {
                    withAnimation { proxy.scrollTo(target, anchor: .top) }
                    focusedName = target
                    scrollTarget = nil
                }
            }
        }
        // Drop back to a menu-bar-only (no Dock, no app menu) app when the
        // management window closes. It only becomes a regular app while open.
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

struct MirrorRow: View {
    @ObservedObject var model: Model
    @Binding var m: MirrorCfg
    @FocusState.Binding var focusedName: String?
    @State private var conflict: String?

    private func binding(_ isSource: Bool) -> Binding<String> {
        Binding(
            get: { isSource ? m.sourceIdentifierGuess(model.calendars) : m.destIdentifierGuess(model.calendars) },
            set: { newId in
                guard let c = model.calendars.first(where: { $0.identifier == newId }) else { return }
                let sT = isSource ? c.title : m.sourceTitle
                let sA = isSource ? c.account : m.sourceAccount
                let dT = isSource ? m.destTitle : c.title
                let dA = isSource ? m.destAccount : c.account
                if let clash = model.reverseConflict(sourceTitle: sT, sourceAccount: sA,
                                                     destTitle: dT, destAccount: dA, excluding: m.id) {
                    conflict = "Can’t reverse “\(clash.name)” — the copy would loop back."
                    return   // reject the change
                }
                conflict = nil
                if isSource { m.sourceTitle = c.title; m.sourceAccount = c.account }
                else { m.destTitle = c.title; m.destAccount = c.account }
                model.saveConfig()
            })
    }

    var body: some View {
        TextField("Name", text: $m.name)
            .focused($focusedName, equals: m.id)
            .onChange(of: m.name) { _, _ in model.saveConfig() }
        Picker("Source", selection: binding(true)) {
            Text("— choose —").tag("")
            ForEach(model.calendars) { c in Text(c.label).tag(c.identifier) }
        }
        Picker("Destination", selection: binding(false)) {
            Text("— choose —").tag("")
            ForEach(model.calendars.filter { $0.writable }) { c in Text(c.label).tag(c.identifier) }
        }
        if let conflict {
            Label(conflict, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        }
        Toggle("Enabled", isOn: $m.enabled).onChange(of: m.enabled) { _, _ in model.saveConfig() }
        Toggle("Heartbeat banner", isOn: $m.showHeartbeat).onChange(of: m.showHeartbeat) { _, _ in model.saveConfig() }

        // "Custom" can't be derived from the fields (it's the absence of a preset
        // match), so the explicit choice is persisted in m.projCustom — it sticks
        // across reopens even when the field combo happens to equal a preset.
        Picker("What to copy", selection: Binding(
            get: { m.projCustom ? .custom : presetOf(m) },
            set: { p in
                if p == .custom { m.projCustom = true }
                else { m.projCustom = false; applyPreset(p, to: &m) }
                model.saveConfig()
            })) {
            Text("Copy details").tag(Preset.details)
            Text("Full copy").tag(Preset.full)
            Text("Busy only").tag(Preset.busy)
            Text("Custom").tag(Preset.custom)
        }
        if m.projTitleRedact {
            TextField("Shown as", text: $m.projTitleText)
                .onChange(of: m.projTitleText) { _, _ in model.saveConfig() }
        }
        if m.projCustom || presetOf(m) == .custom {
            Group {
                Toggle("Redact title", isOn: $m.projTitleRedact).onChange(of: m.projTitleRedact) { _, _ in model.saveConfig() }
                Toggle("Copy location", isOn: $m.projLocation).onChange(of: m.projLocation) { _, _ in model.saveConfig() }
                Toggle("Copy notes", isOn: $m.projNotes).onChange(of: m.projNotes) { _, _ in model.saveConfig() }
                Toggle("Copy alarms", isOn: $m.projAlarms).onChange(of: m.projAlarms) { _, _ in model.saveConfig() }
                Toggle("Always show as busy", isOn: $m.projBusy).onChange(of: m.projBusy) { _, _ in model.saveConfig() }
            }
            .padding(.leading, 12)
        }
        DisclosureGroup("Per-event tags") {
            VStack(alignment: .leading, spacing: 3) {
                Text("Type into a source event's title:").font(.caption).foregroundStyle(.secondary)
                Text("#nomirror — skip this event entirely").font(.caption)
                Text("#private — copy as a busy block").font(.caption)
                Text("#public — copy in full").font(.caption)
            }
        }

        Stepper("History window: \(Int(m.windowPastDays)) days", value: $m.windowPastDays, in: 1...3650, step: 5)
            .onChange(of: m.windowPastDays) { _, _ in model.saveConfig() }
        Stepper("Future window: \(Int(m.windowFutureDays)) days", value: $m.windowFutureDays, in: 1...3650, step: 30)
            .onChange(of: m.windowFutureDays) { _, _ in model.saveConfig() }
        if m.legacyScheme != nil {
            Text("Migrating legacy tags (\(m.legacyScheme!))").font(.caption).foregroundStyle(.secondary)
        }
        Button(role: .destructive) {
            model.mirrors.removeAll { $0.id == m.id }; model.saveConfig()
        } label: { Label("Remove mirror", systemImage: "trash") }
    }
}

extension MirrorCfg {
    func sourceIdentifierGuess(_ cals: [CalInfo]) -> String {
        cals.first { $0.title == sourceTitle && $0.account == sourceAccount }?.identifier
            ?? cals.first { $0.title == sourceTitle }?.identifier ?? ""
    }
    func destIdentifierGuess(_ cals: [CalInfo]) -> String {
        cals.first { $0.title == destTitle && $0.account == destAccount }?.identifier
            ?? cals.first { $0.title == destTitle }?.identifier ?? ""
    }
}

@main
struct CalMirrorMenuApp: App {
    @StateObject private var model = Model()
    var body: some Scene {
        MenuBarExtra { MenuContent(model: model) } label: { Image(systemName: model.overallIcon) }
            .menuBarExtraStyle(.menu)
        Window("Manage Mirrors", id: "manage") { ManageView(model: model) }
    }
}
