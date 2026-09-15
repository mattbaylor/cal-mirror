import SwiftUI
import CalMirrorKit

/// Everything the conflict sheet needs, resolved before it is shown, so the
/// sheet itself derives nothing and can be driven from a fixture.
struct RequestConflict: Identifiable, Equatable {
    let request: IncomingRequest
    /// The nearest offers still open, from `RequestChecker`.
    let alternatives: [Slot]
    /// What is actually on the time now — as intervals, because that is all
    /// `BusyInterval` carries. See the sheet's note on why.
    let landed: [BusyInterval]
    let zone: TimeZone

    var id: String { request.id }
}

/// The conflict sheet — shown when the accept-time re-check finds the slot is
/// no longer clear.
///
/// This screen exists because of the one thing this architecture does better
/// than a hosted competitor: the device holds the truth, so it can notice that
/// something landed between publishing and accepting, and say so *before*
/// writing over it. A hosted service believes its own copy and would write.
///
/// **On "what landed".** It is shown as a time, never a title. `BusyInterval`
/// carries `start`, `end` and `isAllDay` and nothing else — deliberately, since
/// anything the deriver can see is something a future change could publish. So
/// the app genuinely does not know what the clashing event is called, and the
/// sheet says so rather than leaving the owner wondering why their own calendar
/// is being coy. Whether that should change is a question for Matt, not a
/// thing to quietly work around here.
struct RequestConflictSheet: View {
    let conflict: RequestConflict
    let onDecline: () -> Void
    let onAcceptAnyway: () -> Void
    let onLater: () -> Void

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(RequestCopy.Conflict.title).font(.title2.weight(.semibold))
                    Text(String(format: RequestCopy.Conflict.lede,
                                conflict.request.name,
                                RequestNotifications.when(conflict.request.slot, in: conflict.zone)))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(RequestCopy.Conflict.landedHeading) {
                ForEach(Array(conflict.landed.enumerated()), id: \.offset) { _, interval in
                    Text(describe(interval)).font(.callout)
                }
                Text(RequestCopy.Conflict.landedNote)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(RequestCopy.Conflict.alternativesHeading) {
                if conflict.alternatives.isEmpty {
                    Text(RequestCopy.Conflict.noAlternatives)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(conflict.alternatives, id: \.start) { slot in
                        Text(RequestNotifications.when(slot, in: conflict.zone)).font(.callout)
                    }
                    // Said plainly because the obvious expectation is wrong:
                    // there is no counter-offer in the protocol. The requester
                    // asks; the owner accepts or declines. Letting the owner
                    // believe otherwise would produce a decline that the person
                    // on the other end cannot make sense of.
                    Text(RequestCopy.Conflict.alternativesNote)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Button(RequestCopy.Conflict.decline, role: .destructive, action: onDecline)
                Button(RequestCopy.Conflict.later, action: onLater)
                Text(RequestCopy.Conflict.laterNote)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Last, and not styled as the answer. Writing over a real
            // commitment is occasionally exactly right and never the default,
            // so it is available without being offered.
            Section {
                Button(RequestCopy.Conflict.acceptAnyway, action: onAcceptAnyway)
                Text(RequestCopy.Conflict.acceptAnywayNote)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func describe(_ i: BusyInterval) -> String {
        let day = DateFormatter()
        day.timeZone = conflict.zone
        day.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        if i.isAllDay {
            return String(format: RequestCopy.Conflict.landedAllDay, day.string(from: i.start))
        }
        let t = DateFormatter()
        t.timeZone = conflict.zone
        t.setLocalizedDateFormatFromTemplate("j:mm")
        return String(format: RequestCopy.Conflict.landedFormat,
                      day.string(from: i.start),
                      "\(t.string(from: i.start))–\(t.string(from: i.end))")
    }
}

/// One waiting request, with its two answers.
///
/// The requester's name, address and note are here because the owner needs them
/// to decide. They are shown and not stored: the only copy this side keeps is
/// in the accepted event's own notes, and the service purges its copy on its
/// own schedule.
struct RequestRow: View {
    let request: IncomingRequest
    let zone: TimeZone
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(RequestNotifications.when(request.slot, in: zone))
                .font(.headline)
            Text("\(request.name) · \(request.email)")
                .font(.caption).foregroundStyle(.secondary)
            if let note = request.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                Text(note).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(RequestCopy.Notification.accept, action: accept)
                    .buttonStyle(.borderedProminent)
                Button(RequestCopy.Notification.decline, role: .destructive, action: decline)
                    .buttonStyle(.bordered)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
}
