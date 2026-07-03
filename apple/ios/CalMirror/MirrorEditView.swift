import SwiftUI
import CalMirrorKit

struct MirrorEditView: View {
    @EnvironmentObject var model: AppModel
    @Binding var mirror: Mirror

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $mirror.name)
                    .onChange(of: mirror.name) { _, _ in model.save() }
            }
            Section("Calendars") {
                Picker("Source", selection: sourceSelection) {
                    Text("— choose —").tag("")
                    ForEach(model.calendars) { Text($0.label).tag($0.identifier) }
                }
                Picker("Destination", selection: destSelection) {
                    Text("— choose —").tag("")
                    ForEach(model.calendars.filter { $0.writable }) { Text($0.label).tag($0.identifier) }
                }
            }
            Section("Options") {
                Toggle("Enabled", isOn: $mirror.enabled)
                    .onChange(of: mirror.enabled) { _, _ in model.save() }
                Toggle("Heartbeat banner", isOn: $mirror.showHeartbeat)
                    .onChange(of: mirror.showHeartbeat) { _, _ in model.save() }
                Stepper("History: \(Int(mirror.windowPastDays)) days",
                        value: $mirror.windowPastDays, in: 1...3650, step: 5)
                    .onChange(of: mirror.windowPastDays) { _, _ in model.save() }
                Stepper("Future: \(Int(mirror.windowFutureDays)) days",
                        value: $mirror.windowFutureDays, in: 1...3650, step: 30)
                    .onChange(of: mirror.windowFutureDays) { _, _ in model.save() }
            }
            if let ls = mirror.legacyScheme {
                Section { Text("Migrating legacy tags (\(ls))").font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(mirror.name.isEmpty ? "Mirror" : mirror.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sourceSelection: Binding<String> {
        Binding(
            get: { identifier(forTitle: mirror.source.title, account: mirror.source.account) },
            set: { id in
                if let c = model.calendars.first(where: { $0.identifier == id }) {
                    mirror.source = CalRef(title: c.title, account: c.account); model.save()
                }
            })
    }

    private var destSelection: Binding<String> {
        Binding(
            get: { identifier(forTitle: mirror.dest.title, account: mirror.dest.account) },
            set: { id in
                if let c = model.calendars.first(where: { $0.identifier == id }) {
                    mirror.dest = CalRef(title: c.title, account: c.account); model.save()
                }
            })
    }

    private func identifier(forTitle title: String, account: String?) -> String {
        if let acc = account,
           let c = model.calendars.first(where: { $0.title == title && $0.account == acc }) {
            return c.identifier
        }
        return model.calendars.first(where: { $0.title == title })?.identifier ?? ""
    }
}
