import Foundation

public enum RequestPageError: Error, Equatable, Sendable {
    /// No slug yet — the page has not been created.
    case notCreated
    /// The token is not in the store. The page exists but this device cannot
    /// speak for it; the owner has to re-create or restore.
    case noToken
    case noRequestCalendar
    case calendarReadOnly(String)
    /// The dump failed the device-side schema check. The service would refuse
    /// it too; failing here means the owner is told rather than the page
    /// quietly going dark.
    case invalidDump([String])
}

/// What one publish attempt did.
public enum PublishOutcome: Equatable, Sendable {
    case published(slots: Int, reason: PublishPlanner.Reason)
    /// Same offers as the service already has, and recent enough.
    case unchanged
    /// The page is not ready to publish — disabled, no slug, no calendar.
    case notReady
}

/// What accepting did.
public enum AcceptOutcome: Equatable, Sendable {
    /// Written to the calendar and the service told. The requester's `.ics`
    /// is on its way.
    case accepted(eventIdentifier: String)
    /// Something is on that time now. Nothing was written and the service was
    /// not told; the owner decides what to do with the alternatives.
    case conflict(alternatives: [Slot])
    /// The event was written but the service could not be told — network, or
    /// the service is down. The event is real; call `accept` again and it
    /// finds the event it already wrote and only retries the resolve.
    case writtenButNotResolved(eventIdentifier: String, AskwhenError)
}

/// The device side of the dead drop, in the order the architecture (§6) lists:
/// publish, collect, resolve. Holds no state of its own — everything it
/// remembers is in the `RequestPageConfig` it is handed, so the caller saves
/// it and the next cycle picks up where this one left off.
///
/// One instance per app, like `MirrorEngine`. Not thread-safe; the caller
/// serialises calls the way it serialises syncs.
public final class RequestPageCoordinator: @unchecked Sendable {
    private let engine: MirrorEngine
    private let client: AskwhenClient
    private let tokens: TokenStore
    /// Where the engine holds its calendar events. Only a pure caller — a test,
    /// a diagnostic — swaps it.
    public typealias BusySource = (_ calendars: [CalRef], _ from: Date, _ to: Date) -> [BusyInterval]
    private let busySource: BusySource

    public init(engine: MirrorEngine, client: AskwhenClient = AskwhenClient(), tokens: TokenStore,
                busySource: BusySource? = nil) {
        self.engine = engine
        self.client = client
        self.tokens = tokens
        self.busySource = busySource ?? { engine.busyIntervals(in: $0, from: $1, to: $2) }
    }

    // MARK: Create

    /// Creates the page and stores its token. The only place the token is ever
    /// seen in the clear; `page.slug` is set on return.
    public func create(page: inout RequestPageConfig, entitlementHash: String) async throws {
        let display = PolicyDump.Display(name: page.displayName, blurb: page.blurb, tz: page.policy.timeZone)
        let created = try await client.createPage(entitlementHash: entitlementHash, display: display)
        try tokens.store(created.writeToken, for: created.slug)
        page.slug = created.slug
        page.lastPublishedFingerprint = nil
        page.lastPublishedAt = nil
        page.queueETag = nil
    }

    /// Deletes the page — its queue and domains go with it — and forgets the
    /// token. Permanent, which is why it is the one call here with no retry
    /// story: a 404 back means it is already gone, and that is success.
    public func delete(page: inout RequestPageConfig) async throws {
        guard !page.slug.isEmpty else { return }
        if let token = try tokens.token(for: page.slug) {
            do { try await client.deletePage(slug: page.slug, token: token) }
            catch AskwhenError.notFound {}
        }
        try tokens.remove(for: page.slug)
        page.slug = ""
        page.lastPublishedFingerprint = nil
        page.lastPublishedAt = nil
        page.queueETag = nil
    }

    // MARK: Publish

    /// Derive, compare, and PUT only if the offers changed or the last upload
    /// is going stale. Piggybacks the sync loop: realtime already means "the
    /// calendar moved", and this is what the calendar moving should do next.
    public func publishIfNeeded(page: inout RequestPageConfig, now: Date = Date()) async throws -> PublishOutcome {
        guard page.isReady else { return .notReady }
        guard let token = try tokens.token(for: page.slug) else { throw RequestPageError.noToken }

        let horizon = now.addingTimeInterval(TimeInterval(page.policy.horizonDays + 1) * 86400)
        let busy = busySource(page.blocking, now.addingTimeInterval(-86400), horizon)
        let dump = PolicyDump.make(from: page, busy: busy, now: now)
        let problems = dump.validationProblems
        guard problems.isEmpty else { throw RequestPageError.invalidDump(problems) }

        let fingerprint = dump.contentFingerprint()
        let decision = PublishPlanner.decide(fingerprint: fingerprint,
                                             lastFingerprint: page.lastPublishedFingerprint,
                                             lastPublishedAt: page.lastPublishedAt, now: now)
        guard case .publish(let reason) = decision else { return .unchanged }

        _ = try await client.publish(try dump.encoded(), slug: page.slug, token: token)
        page.lastPublishedFingerprint = fingerprint
        page.lastPublishedAt = now
        return .published(slots: dump.slots.count, reason: reason)
    }

    // MARK: Collect

    /// Polls the queue. `nil` means nothing changed since the last poll — the
    /// caller keeps whatever it was showing. Otherwise the full current queue.
    public func collect(page: inout RequestPageConfig) async throws -> [IncomingRequest]? {
        guard page.isReady else { return nil }
        guard let token = try tokens.token(for: page.slug) else { throw RequestPageError.noToken }
        switch try await client.queue(slug: page.slug, token: token, ifNoneMatch: page.queueETag) {
        case .unchanged:
            return nil
        case .changed(let requests, let etag):
            page.queueETag = etag
            return requests
        }
    }

    // MARK: Resolve

    /// Accept, in the architecture's order: re-check the calendar, write the
    /// event, tell the service. Each step only happens if the one before it
    /// did, and the write is idempotent on the request id, so calling this
    /// again after a failure is safe.
    public func accept(_ request: IncomingRequest, page: inout RequestPageConfig,
                       now: Date = Date()) async throws -> AcceptOutcome {
        guard let token = try tokens.token(for: page.slug) else { throw RequestPageError.noToken }
        guard let calendar = page.requestCalendar else { throw RequestPageError.noRequestCalendar }

        // 1. The dump was a snapshot. The calendar is the truth.
        let horizon = now.addingTimeInterval(TimeInterval(page.policy.horizonDays + 1) * 86400)
        let busy = busySource(page.blocking, min(now, request.slot.start).addingTimeInterval(-86400), horizon)
        if case .conflict(let alternatives) = RequestChecker.check(slot: request.slot, policy: page.policy,
                                                                   busy: busy, now: now) {
            return .conflict(alternatives: alternatives)
        }

        // 2. Write it. Title is the owner's; the requester's words go in the
        //    body, where they are obviously theirs.
        let notes = Self.notes(for: request)
        let eventID = try engine.writeAcceptedEvent(requestID: request.id, title: page.meetingTitle,
                                                    location: page.meetingLocation, notes: notes,
                                                    start: request.slot.start, end: request.slot.end,
                                                    into: calendar)

        // 3. Tell the service, so it can email the .ics. A 404 here means it was
        //    already resolved — by this device a moment ago, or another — and
        //    the event is written, so that is done, not failed.
        do {
            try await client.resolve(requestID: request.id, slug: page.slug, decision: .accept, token: token)
        } catch AskwhenError.notFound {
        } catch let e as AskwhenError {
            return .writtenButNotResolved(eventIdentifier: eventID, e)
        }
        page.queueETag = nil   // the queue changed; the next poll must not 304
        return .accepted(eventIdentifier: eventID)
    }

    /// Decline. Nothing is written; the service releases the hold and emails.
    public func decline(_ request: IncomingRequest, page: inout RequestPageConfig) async throws {
        guard let token = try tokens.token(for: page.slug) else { throw RequestPageError.noToken }
        do {
            try await client.resolve(requestID: request.id, slug: page.slug, decision: .decline, token: token)
        } catch AskwhenError.notFound {}
        page.queueETag = nil
    }

    /// The event body. Name and address so the owner can reach them — this is
    /// the one place the address is kept, in the owner's own calendar, which
    /// is where they would expect to find it.
    static func notes(for r: IncomingRequest) -> String {
        var lines = ["Requested by \(r.name) <\(r.email)> via askwhen.me"]
        if let note = r.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            lines.append("")
            lines.append(note)
        }
        return lines.joined(separator: "\n")
    }
}
