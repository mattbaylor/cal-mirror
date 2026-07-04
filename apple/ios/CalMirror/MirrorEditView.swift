import SwiftUI
import CalMirrorKit

struct MirrorEditView: View {
    @EnvironmentObject var model: Store
    @Binding var mirror: Mirror

    var body: some View {
        Form {
            Section {
                MirrorFields(
                    mirror: $mirror,
                    calendars: model.calendars,
                    reverseConflict: { s, d in model.wouldReverse(source: s, dest: d, excluding: mirror.id) },
                    onChange: { model.save() })
            }
            Section {
                Toggle("Enabled", isOn: $mirror.enabled)
                    .onChange(of: mirror.enabled) { _, _ in model.save() }
            }
            if let ls = mirror.legacyScheme {
                Section { Text("Migrating legacy tags (\(ls))").font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(mirror.name.isEmpty ? "Mirror" : mirror.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
