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

    @State private var notifyStatus: UNAuthorizationStatus = .notDetermined

    private var url: String { "askwhen.me/\(page.slug)" }
    private var shareURL: URL { URL(string: "https://\(url)")! }

    var body: some View {
        // The headline, the address, and two tinted rows. One button style
        // on the screen, not three (native.md, §5): sharing is the system's
        // sheet, which covers copy, Messages, Mail and AirDrop.
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(RequestCopy.Live.heading).font(.title2.weight(.semibold))
                Text(RequestCopy.Live.lede).fixedSize(horizontal: false, vertical: true)
                Text(url)
                    .font(.system(.title3, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.top, 4)
                if page.lastPublishedAt == nil {
                    Text(RequestCopy.Live.notPublished)
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ShareLink(item: shareURL) {
                Text(RequestCopy.Live.share)
            }
            Link(RequestCopy.Live.openTitle, destination: shareURL)
        } footer: {
            Text(RequestCopy.Live.linkFooter)
        }

        // Asked here and not at launch, and not at the start of setup:
        // requests cannot arrive before there is a page, so asking earlier
        // would be asking permission to do nothing. The section goes away
        // once granted; while denied it says where the switch is.
        if notifyStatus == .notDetermined || notifyStatus == .denied {
            Section {
                if notifyStatus == .denied {
                    Label(RequestCopy.Notification.permissionDenied, systemImage: "bell.slash")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Button(RequestCopy.Notification.permissionAsk) {
                        Task {
                            _ = await RequestNotifications.requestPermission()
                            RequestNotifications.registerCategory()
                            notifyStatus = await RequestNotifications.authorization()
                        }
                    }
                }
            } header: {
                Text(RequestCopy.Notification.permissionHeading)
            } footer: {
                // The consequence is stated because it is real — a stranger's
                // name and note land on a lock screen.
                Text(RequestCopy.Notification.permissionFooter)
            }
        }

        // What this device is to the page, as facts with checkmarks, and the
        // one switch. Publisher nomination (screen 10) is folded in here as a
        // statement rather than given a screen: with one device it is a
        // question with no second answer. The key warning is the important
        // fact — no account, no password, so the keychain entry is genuinely
        // the only thing keeping the page theirs.
        Section {
            LabeledContent(RequestCopy.Live.publishes) {
                Image(systemName: "checkmark").foregroundStyle(.secondary)
            }
            LabeledContent(RequestCopy.Live.holdsKey) {
                Image(systemName: "checkmark").foregroundStyle(.secondary)
            }
            // Off, not delete. Deleting the page takes the slug with it and
            // every link already sent goes dead, so that belongs behind a
            // confirmation rather than beside a switch.
            Toggle(RequestCopy.Live.turnOff, isOn: Binding(
                get: { page.enabled },
                set: { page.enabled = $0; onChange() }))
        } header: {
            Text(RequestCopy.Live.deviceSection)
        } footer: {
            Text(RequestCopy.Live.deviceFooter)
        }
        .task { await refreshStatus() }
    }

    private func refreshStatus() async {
        notifyStatus = await RequestNotifications.authorization()
        if notifyStatus != .notDetermined { RequestNotifications.registerCategory() }
    }
}
