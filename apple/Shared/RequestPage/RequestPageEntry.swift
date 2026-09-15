import SwiftUI
import CalMirrorKit

/// Screens 1 and 2 — the dormant row, and the explainer that is the opt-in.
///
/// **Everything here is local.** Nothing in this file may touch the network:
/// no product fetch, no version check, no page creation. `decisions.md`,
/// "The product load happens on the offer screen", puts the app's first
/// network request of any kind on screen 7, which is several steps after the
/// button below. An owner can read this, walk the whole of setup, decide
/// against it and close the app having sent nothing anywhere.

// MARK: - Screen 1

/// The row an owner who has never heard of this meets. It is drawn from
/// `Config` alone, so a fresh install renders it with no work and no traffic.
/// Content only, with no tap handling of its own: iOS puts it inside a
/// `NavigationLink` and the Mac inside a `Button`, and a row that brought its
/// own Button would nest a control inside a control on one of them.
struct RequestPageRow: View {
    let page: RequestPageConfig?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(RequestCopy.DormantRow.title)
                Text(subtitle)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
            Text(state).font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(RequestCopy.DormantRow.title), \(state)")
        .accessibilityHint(subtitle)
    }

    /// Off is the whole story until there is a page; once there is one, the
    /// slug is more use than the word "On", because it is the thing the owner
    /// wants to read back.
    private var state: String {
        guard let p = page, p.enabled else { return RequestCopy.DormantRow.off }
        return p.slug.isEmpty ? "Not published" : "askwhen.me/\(p.slug)"
    }

    /// The pitch is only worth the space while it is still a pitch.
    private var subtitle: String {
        guard let p = page, p.enabled else { return RequestCopy.DormantRow.blurbForPlatform }
        return p.displayName.isEmpty ? "Set up" : p.displayName
    }
}

// MARK: - Screen 2

/// The explainer. Deliberately long: this is the only screen where the owner is
/// deciding whether to have a server in their life at all, and the privacy
/// consequence is the product. Density would be the wrong economy here.
struct RequestPageExplainer: View {
    /// Moves to screen 3. Does not enable anything by itself — `enabled` is set
    /// when there is a page to enable, so backing out of setup leaves no trace.
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(RequestCopy.Explainer.title)
                    .font(.largeTitle.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(RequestCopy.Explainer.paragraphs, id: \.self) { p in
                    Text(p).fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(RequestCopy.Explainer.costHeading)
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    // Said here rather than at the offer screen, so that the
                    // price at the end of setup is something the owner was
                    // told about at the start rather than something they
                    // walked into. See decisions.md, "The trial opt-in comes
                    // after the preview" — the ordering only reads as honest
                    // if the cost is disclosed before the work, not after it.
                    Text(RequestCopy.Explainer.cost)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)

                Button(RequestCopy.Explainer.primary, action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                Text(RequestCopy.Explainer.footnote)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: 560, alignment: .leading)
        }
    }
}
