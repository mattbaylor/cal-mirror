import SwiftUI
import CalMirrorKit

/// One mirror's settings. The pair itself is on this screen because it's what
/// you came here to check; everything else collapses to a summary row that says
/// what it's set to, and pushes its controls onto their own screen. With ten
/// mirrors configured, that's the difference between a scannable list and a
/// two-thousand-point scroll.
struct MirrorEditView: View {
    @EnvironmentObject var model: Store
    @Binding var mirror: Mirror

    var body: some View {
        Form {
            Section("Pair") {
                PairFields(
                    mirror: $mirror,
                    calendars: model.calendars,
                    reverseConflict: { s, d in model.wouldReverse(source: s, dest: d, excluding: mirror.id) },
                    onChange: { model.save() })
                Toggle("Enabled", isOn: $mirror.enabled)
                    .onChange(of: mirror.enabled) { _, _ in model.save() }
            }

            Section {
                NavigationLink {
                    Form { Section { ProjectionFields(mirror: $mirror, onChange: { model.save() }) } }
                        .navigationTitle("What crosses over")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    // The summary goes on the detail line, not the trailing
                    // value: a custom projection is several clauses long and
                    // would wrap into the label beside it.
                    SummaryRow(title: "What crosses over",
                               value: nil,
                               detail: MirrorSummary.projection(mirror.projection))
                }

                NavigationLink {
                    Form { SelectionFields(mirror: $mirror, onChange: { model.save() }) }
                        .navigationTitle("Which events")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    SummaryRow(title: "Which events",
                               value: ruleCountLabel,
                               detail: MirrorSummary.selection(mirror.filters, tagFilter: mirror.tagFilter))
                }
            }

            Section {
                NavigationLink {
                    Form { Section { AdvancedFields(mirror: $mirror, onChange: { model.save() }) } }
                        .navigationTitle("Advanced")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    SummaryRow(title: "Advanced", value: nil, detail: MirrorSummary.advanced(mirror))
                }
            }

            if let ls = mirror.legacyScheme {
                Section { Text("Migrating legacy tags (\(ls))").font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(mirror.name.isEmpty ? "Mirror" : mirror.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var ruleCountLabel: String? {
        var n = mirror.filters.activeRuleCount
        if mirror.tagFilter?.isActive == true { n += 1 }
        guard n > 0 else { return nil }
        return n == 1 ? "1 rule" : "\(n) rules"
    }
}

/// A row that names a section and says what it's currently set to, so the
/// collapsed state still carries the answer.
struct SummaryRow: View {
    let title: String
    let value: String?
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                if let value { Text(value).foregroundStyle(.secondary) }
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
        }
    }
}
