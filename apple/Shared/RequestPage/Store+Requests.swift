import SwiftUI
import CalMirrorKit

/// Collecting requests and answering them.
///
/// The pace is not decided here — `decisions.md` settled that it is inferred
/// from the sync settings the owner already chose, so this is called from the
/// same places a sync is and never on a schedule of its own.
extension Store {

    /// Poll, post a notification for anything new, and keep what is live so
    /// the UI can list it. Returns silently when the page is not ready: a page
    /// that is off must make no network request, and that is the whole promise.
    func collectRequests() async {
        guard requestPage.isReady else { return }
        var page = requestPage
        do {
            guard let collected = try await requestCoordinator().collect(page: &page) else { return }
            requestPage = page
            save()

            // Only what is new. A 304 is handled above, but a queue that
            // changed for another reason — one request answered, three still
            // waiting — must not re-notify the three.
            let known = Set(pendingRequests.map(\.id))
            var remaining = collected
            for request in collected where !known.contains(request.id) {
                // Through a personal link, the owner already said yes when
                // they sent it: accept now if the slot is still clear, and
                // say so. A conflict stays in the queue and gets the sheet,
                // as a public request would — the consent was to a clear
                // time, not to a double booking.
                if request.personal, let outcome = await acceptIfClear(request) {
                    RequestNotifications.postOutcome(outcome, for: request, zone: zone)
                    if case .accepted = outcome { remaining.removeAll { $0.id == request.id }; continue }
                    if case .conflict = outcome { continue }   // the sheet is up; no second notification
                }
                RequestNotifications.post(request, zone: zone)
            }
            // Anything that left the queue was answered elsewhere; its
            // notification is now a button that would do nothing.
            for gone in known.subtracting(Set(collected.map(\.id))) {
                RequestNotifications.clear(gone)
            }
            pendingRequests = remaining
        } catch {
            // A failed poll is polled again. Nothing is shown for it: the
            // owner did not ask for this to happen now, and an error about
            // something they did not do is noise.
        }
    }

    /// Accept, with the re-check that makes this architecture more accurate at
    /// the moment of truth rather than less. A conflict writes nothing and
    /// tells nobody — it becomes the sheet.
    @discardableResult
    func accept(_ request: IncomingRequest) async -> AcceptOutcome? {
        var page = requestPage
        do {
            let outcome = try await requestCoordinator().accept(request, page: &page)
            requestPage = page
            save()
            switch outcome {
            case .accepted:
                finish(request)
            case .conflict(let alternatives):
                // Resolved here rather than in the sheet so the sheet derives
                // nothing and can be driven from a fixture.
                conflict = RequestConflict(request: request,
                                           alternatives: alternatives,
                                           landed: landed(on: request.slot),
                                           zone: zone)
            case .writtenButNotResolved:
                // The event is real; only the service does not know. Keep it
                // in the queue so accepting again retries just the resolve.
                break
            }
            return outcome
        } catch {
            return nil
        }
    }

    /// The accept-at-send-time path for a request through a personal link.
    /// Nil when the attempt itself failed (no token, no calendar), in which
    /// case the request is treated as an ordinary one and notified.
    private func acceptIfClear(_ request: IncomingRequest) async -> AcceptOutcome? {
        var page = requestPage
        do {
            let outcome = try await requestCoordinator().acceptIfClear(request, page: &page)
            requestPage = page
            save()
            if case .conflict(let alternatives) = outcome {
                conflict = RequestConflict(request: request, alternatives: alternatives,
                                           landed: landed(on: request.slot), zone: zone)
            }
            return outcome
        } catch {
            return nil
        }
    }

    /// A decline the service did not take is not a decline: the requester
    /// hears nothing, the hold stands, and the next poll brings the request
    /// straight back. So it stays in the queue, still waiting, rather than
    /// being reported as answered — the same shape as `writtenButNotResolved`
    /// on the accept side.
    func decline(_ request: IncomingRequest) async {
        var page = requestPage
        do {
            try await requestCoordinator().decline(request, page: &page)
        } catch {
            requestPage = page
            save()
            if conflict?.id == request.id { conflict = nil }
            return
        }
        requestPage = page
        save()
        finish(request)
        RequestNotifications.postDeclined(request)
    }

    /// Accept over the top of whatever is there. The re-check is skipped on
    /// purpose — the owner has just been shown the clash and said to do it
    /// anyway, and asking again would be asking the same question twice.
    func acceptAnyway(_ request: IncomingRequest) async {
        var page = requestPage
        _ = try? await requestCoordinator().accept(request, page: &page, overridingConflict: true)
        requestPage = page
        save()
        finish(request)
    }

    // MARK: From a notification

    /// The request may be gone — answered on another device, or expired — in
    /// which case there is nothing to do and saying so would be noise.
    ///
    /// The queue is not persisted, so after a launch from the notification
    /// itself it is empty; the request is looked up again before giving up,
    /// the way `openRequest` does. Without that, Accept on a lock screen
    /// worked only while the app happened to be alive.
    func acceptFromNotification(_ id: String) async {
        guard let request = await pending(id) else { return }
        if let outcome = await accept(request) {
            RequestNotifications.postOutcome(outcome, for: request, zone: zone)
        }
    }

    func declineFromNotification(_ id: String) async {
        guard let request = await pending(id) else { return }
        await decline(request)
    }

    private func pending(_ id: String) async -> IncomingRequest? {
        if pendingRequests.isEmpty { await collectRequests() }
        return pendingRequests.first(where: { $0.id == id })
    }

    /// A plain tap, or the conflict notification. Surfaces the request without
    /// answering it.
    func openRequest(_ id: String) async {
        if pendingRequests.isEmpty { await collectRequests() }
        openedRequestID = id
        if let request = pendingRequests.first(where: { $0.id == id }),
           conflict == nil,
           case .conflict(let alternatives) = RequestChecker.check(
               slot: request.slot, policy: requestPage.policy,
               busy: busySource(requestPage.blocking,
                                request.slot.start.addingTimeInterval(-86400),
                                request.slot.end.addingTimeInterval(86400)),
               now: Date()) {
            conflict = RequestConflict(request: request, alternatives: alternatives,
                                       landed: landed(on: request.slot), zone: zone)
        }
    }

    // MARK: Pieces

    private func finish(_ request: IncomingRequest) {
        pendingRequests.removeAll { $0.id == request.id }
        RequestNotifications.clear(request.id)
        if conflict?.id == request.id { conflict = nil }
    }

    /// What is on the slot now, buffered the way the checker buffers it, so the
    /// sheet shows the same thing that caused the conflict rather than a
    /// narrower window that might show nothing at all.
    private func landed(on slot: Slot) -> [BusyInterval] {
        let buffer = TimeInterval(requestPage.policy.bufferMinutes) * 60
        let from = slot.start.addingTimeInterval(-buffer)
        let to = slot.end.addingTimeInterval(buffer)
        return busySource(requestPage.blocking,
                          from.addingTimeInterval(-86400),
                          to.addingTimeInterval(86400))
            .filter { b in
                if b.isAllDay {
                    var cal = Calendar(identifier: .gregorian)
                    cal.timeZone = zone
                    let day = cal.startOfDay(for: slot.start)
                    let next = cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
                    return b.start < next && b.end > day
                }
                return from < b.end && to > b.start
            }
    }

    var zone: TimeZone { requestPage.policy.resolvedTimeZone ?? .current }
}
