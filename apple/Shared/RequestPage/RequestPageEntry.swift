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

/// The explainer, as the standard first-run sheet: a symbol, a title, three
/// feature rows, one footnote, and the primary action pinned to the bottom
/// (`apple/design/native.md`, section 1). It is presented modally from the
/// row on iOS and is the first content of the setup sheet on the Mac; either
/// way it is not a screen on the navigation stack.
///
/// The four paragraphs it used to be are under `longForm` in `Copy.json`.
/// Everything they said is still true; on a phone, reading is not the
/// activity, and the price is still named before any work is asked for —
/// `decisions.md`, "The trial opt-in comes after the preview".
struct RequestPageExplainer: View {
    /// Moves to screen 3. Does not enable anything by itself — `enabled` is set
    /// when there is a page to enable, so backing out of setup leaves no trace.
    let onContinue: () -> Void
    /// "Not now". Nil where the container already has its own way out (the
    /// Mac sheet's Done button), so the sheet does not offer two.
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    Image(systemName: RequestCopy.Explainer.symbol)
                        .font(.system(size: 56, weight: .medium))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text(RequestCopy.Explainer.title)
                        .font(.title.weight(.bold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 36)

                VStack(alignment: .leading, spacing: 22) {
                    ForEach(RequestCopy.Explainer.features, id: \.headline) { f in
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: f.symbol)
                                .font(.title2)
                                .foregroundStyle(.tint)
                                .frame(width: 36)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.headline).font(.headline)
                                Text(f.line).font(.subheadline).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.horizontal, 8)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 14) {
                // The one line that keeps the ordering honest: the cost is
                // said here, before any work, not sprung at screen 7.
                Text(RequestCopy.Explainer.footnote)
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onContinue) {
                    Text(RequestCopy.Explainer.primary).frame(maxWidth: .infinity)
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                if let onDismiss {
                    Button(RequestCopy.Explainer.secondary, action: onDismiss)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }
}
