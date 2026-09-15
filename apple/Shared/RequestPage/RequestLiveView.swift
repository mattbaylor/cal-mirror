import SwiftUI
import CalMirrorKit

/// Screen 9 — the page exists. The URL, and the two facts an owner has to be
/// told exactly once, at the only moment they will believe them.
///
/// The write token warning is the important one. `askwhen.me` has no account,
/// no address for the owner and no password, so the Keychain entry on this
/// device is genuinely the only thing keeping the page theirs. Saying so here
/// is the difference between a design property and a support problem.
struct RequestLiveView: View {
    @Binding var page: RequestPageConfig
    let onChange: () -> Void

    @State private var copied = false

    private var url: String { "askwhen.me/\(page.slug)" }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(RequestCopy.Live.heading).font(.title2.weight(.semibold))
                Text(RequestCopy.Live.lede).fixedSize(horizontal: false, vertical: true)
                Text(url)
                    .font(.system(.title3, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.top, 4)
                if page.lastPublishedAt == nil {
                    Text(RequestCopy.Live.notPublished)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button(copied ? RequestCopy.Live.copied : RequestCopy.Live.copy) {
                copy("https://\(url)")
            }
            .buttonStyle(.borderedProminent)
            Link(RequestCopy.Live.openTitle, destination: URL(string: "https://\(url)")!)
            Text(RequestCopy.Live.openNote).font(.caption).foregroundStyle(.secondary)
        } header: {
            Text(RequestCopy.Live.section)
        }

        Section(RequestCopy.Live.tokenHeading) {
            Text(RequestCopy.Live.tokenBody)
                .font(.callout).fixedSize(horizontal: false, vertical: true)
        }

        // Screen 10, folded in here rather than given a screen of its own: an
        // owner setting up their first device is not choosing between devices
        // yet, and a nomination screen with one candidate on it asks a question
        // that has no second answer. It becomes a real choice when a second
        // device appears, which is where it should first be offered.
        Section(RequestCopy.Live.publisherHeading) {
            Text(RequestCopy.Live.publisherBody)
                .font(.callout).fixedSize(horizontal: false, vertical: true)
        }

        Section(RequestCopy.Live.offHeading) {
            Text(RequestCopy.Live.offBody)
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            // Off, not delete. Deleting the page takes the slug with it and
            // every link already sent goes dead, so that belongs behind a
            // confirmation rather than beside an explanation.
            Toggle(RequestCopy.Live.turnOff, isOn: Binding(
                get: { !page.enabled },
                set: { page.enabled = !$0; onChange() }))
        }
    }

    private func copy(_ s: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #else
        UIPasteboard.general.string = s
        #endif
        copied = true
    }
}
