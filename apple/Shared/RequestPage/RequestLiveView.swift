import SwiftUI
import UserNotifications
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
    @State private var notifyStatus: UNAuthorizationStatus = .notDetermined

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

        // Asked here and not at launch, and not at the start of setup:
        // requests cannot arrive before there is a page, so asking earlier
        // would be asking permission to do nothing. The consequence is stated
        // because it is real — a stranger's name and note land on a lock
        // screen, and the owner should know that before saying yes.
        Section(RequestCopy.Notification.permissionHeading) {
            Text(RequestCopy.Notification.permissionBody)
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(RequestCopy.Notification.permissionNote)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switch notifyStatus {
            case .notDetermined:
                Button(RequestCopy.Notification.permissionAsk) {
                    Task {
                        _ = await RequestNotifications.requestPermission()
                        RequestNotifications.registerCategory()
                        notifyStatus = await RequestNotifications.authorization()
                    }
                }
                .buttonStyle(.borderedProminent)
            case .denied:
                Label(RequestCopy.Notification.permissionDenied, systemImage: "bell.slash")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                Label("On", systemImage: "bell.badge").font(.caption).foregroundStyle(.secondary)
            }
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
        .task { await refreshStatus() }
    }

    private func refreshStatus() async {
        notifyStatus = await RequestNotifications.authorization()
        if notifyStatus != .notDetermined { RequestNotifications.registerCategory() }
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
