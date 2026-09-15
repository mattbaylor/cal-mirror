import SwiftUI
import CalMirrorKit

/// Screen 4 — the page's face, and who gets to name the event.
///
/// Two groups because they answer two different questions. The first is *what a
/// stranger sees*: the display name is the only identifying field in the dump
/// (`decisions.md`, "Display name — required, any label the owner chooses"), so
/// its caption says so rather than treating it as an ordinary text field.
///
/// The second is *what lands in the owner's calendar*. Both fields there are the
/// owner's, deliberately: letting a requester name an event puts unreviewed
/// stranger text into a calendar, which `decisions.md` settled against.
struct RequestDisplayFields: View {
    @Binding var page: RequestPageConfig
    let onChange: () -> Void

    var body: some View {
        Section(RequestCopy.Display.section) {
            TextField(RequestCopy.Display.nameTitle,
                      text: $page.displayName,
                      prompt: Text(RequestCopy.Display.namePlaceholder))
                .onChange(of: page.displayName) { _, _ in onChange() }
            Text(RequestCopy.Display.nameCaption)
                .font(.caption).foregroundStyle(.secondary)

            // Shown only while it is true. `isReady` refuses to publish without
            // a name anyway; this says why before the owner reaches a screen
            // that will not let them through.
            if page.displayName.trimmingCharacters(in: .whitespaces).isEmpty {
                Label(RequestCopy.Display.nameMissing, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            TextField(RequestCopy.Display.blurbTitle,
                      text: optional($page.blurb),
                      prompt: Text(RequestCopy.Display.blurbPlaceholder),
                      axis: .vertical)
                .lineLimit(1...3)
                .onChange(of: page.blurb) { _, _ in onChange() }
            Text(RequestCopy.Display.blurbCaption)
                .font(.caption).foregroundStyle(.secondary)
        }

        Section(RequestCopy.Display.meetingSection) {
            TextField(RequestCopy.Display.titleTitle,
                      text: $page.meetingTitle,
                      prompt: Text(RequestCopy.Display.titlePlaceholder))
                .onChange(of: page.meetingTitle) { _, _ in onChange() }
            Text(RequestCopy.Display.titleCaption)
                .font(.caption).foregroundStyle(.secondary)

            TextField(RequestCopy.Display.locationTitle,
                      text: optional($page.meetingLocation),
                      prompt: Text(RequestCopy.Display.locationPlaceholder))
                .onChange(of: page.meetingLocation) { _, _ in onChange() }
            Text(RequestCopy.Display.locationCaption)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// `TextField` wants a non-optional `String`; the config stores `String?`
    /// because an absent blurb and an empty one are the same thing to the dump
    /// and only one of them should be encoded. Emptied text becomes nil so the
    /// published document carries no empty key.
    private func optional(_ b: Binding<String?>) -> Binding<String> {
        Binding(get: { b.wrappedValue ?? "" },
                set: { s in
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    b.wrappedValue = t.isEmpty ? nil : s
                })
    }
}
