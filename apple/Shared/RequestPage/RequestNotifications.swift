import Foundation
import UserNotifications
import CalMirrorKit

/// One notification per collected request, carrying Accept and Decline.
///
/// **Why a notification at all.** Nothing is pushed to the owner — the service
/// holds no address for them and could not reach them if it wanted to. The
/// device collects, and this is how the device tells its owner. So the
/// notification is not a convenience layered on a feed; it *is* the arrival.
///
/// **Accept cannot promise to succeed.** The dump was a snapshot and the
/// calendar is the truth, so accepting re-checks first and may find the time
/// taken (`architecture.md` §6). A notification action that claimed otherwise
/// would be lying at the one moment accuracy is the whole argument. So the
/// fast path stays fast — accept from the notification, done — and a conflict
/// posts a second notification that opens the conflict sheet.
enum RequestNotifications {

    /// Registered when the page goes live, not at launch. Requests cannot
    /// arrive before there is a page, so asking earlier would be asking for
    /// permission to do nothing.
    static func registerCategory() {
        let accept = UNNotificationAction(
            identifier: RequestCopy.Notification.acceptId,
            title: RequestCopy.Notification.accept,
            options: [.authenticationRequired])
        let decline = UNNotificationAction(
            identifier: RequestCopy.Notification.declineId,
            title: RequestCopy.Notification.decline,
            options: [.destructive, .authenticationRequired])
        let category = UNNotificationCategory(
            identifier: RequestCopy.Notification.categoryId,
            actions: [accept, decline],
            intentIdentifiers: [],
            options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Asked for at the end of setup, with the consequence stated — the
    /// requester's name and note are in the notification body, which means
    /// they can appear on a locked screen.
    @discardableResult
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func authorization() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// One notification per request, identified by the request id so the same
    /// request collected twice replaces its own notification rather than
    /// stacking a second copy of itself.
    static func post(_ request: IncomingRequest, zone: TimeZone) {
        let content = UNMutableNotificationContent()
        content.title = String(format: RequestCopy.Notification.titleFormat, request.name)
        content.subtitle = when(request.slot, in: zone)
        if let note = request.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            content.body = note
        }
        content.categoryIdentifier = RequestCopy.Notification.categoryId
        content.userInfo = ["requestID": request.id]
        content.sound = .default
        submit(id: "request-\(request.id)", content)
    }

    /// The outcome, said back. An Accept tapped on a lock screen otherwise
    /// gives no sign it worked, and "did that go through?" is exactly the
    /// question that makes someone open the app and accept a second time.
    static func postOutcome(_ outcome: AcceptOutcome, for request: IncomingRequest, zone: TimeZone) {
        let content = UNMutableNotificationContent()
        let slot = when(request.slot, in: zone)
        switch outcome {
        case .accepted:
            content.title = RequestCopy.Notification.acceptedTitle
            content.body = String(format: RequestCopy.Notification.acceptedBody, request.name)
        case .conflict:
            content.title = RequestCopy.Notification.conflictTitle
            content.body = String(format: RequestCopy.Notification.conflictBody, slot)
            content.userInfo = ["conflictRequestID": request.id]
        case .writtenButNotResolved:
            content.title = RequestCopy.Notification.failedTitle
            content.body = RequestCopy.Notification.failedBody
            content.userInfo = ["requestID": request.id]
        }
        submit(id: "outcome-\(request.id)", content)
    }

    static func postDeclined(_ request: IncomingRequest) {
        let content = UNMutableNotificationContent()
        content.title = RequestCopy.Notification.declinedTitle
        content.body = String(format: RequestCopy.Notification.declinedBody, request.name)
        submit(id: "outcome-\(request.id)", content)
    }

    /// Clears a request's notification — it was answered somewhere else, on
    /// another device or in the app. A dead Accept button on a lock screen is
    /// worse than no button.
    static func clear(_ requestID: String) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ["request-\(requestID)"])
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: ["request-\(requestID)"])
    }

    private static func submit(id: String, _ content: UNMutableNotificationContent) {
        // nil trigger: deliver now. The request already waited for a poll.
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// "Tuesday 16 September, 3:00 PM". The owner's own zone, because this is
    /// the owner's device and their calendar is what the time will land in.
    static func when(_ slot: Slot, in zone: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = zone
        f.setLocalizedDateFormatFromTemplate("EEEE d MMMM, j:mm")
        return f.string(from: slot.start)
    }
}

/// Routes the two actions back into the app.
///
/// Held by the app rather than by `Store` so it survives a launch triggered by
/// the notification itself — iOS may deliver the response before any view
/// exists, and an action that only worked while a window was open would fail
/// exactly when it was most useful.
@MainActor
final class RequestNotificationDelegate: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    weak var store: Store?
    /// Set when a conflict needs the sheet. The UI observes it and presents.
    @Published var conflict: RequestConflict?

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let id = info["requestID"] as? String ?? info["conflictRequestID"] as? String else { return }
        await handle(action: response.actionIdentifier, requestID: id)
    }

    /// Shown even while the app is in front. A request that arrived during a
    /// sync the owner was watching is still news, and suppressing it would
    /// make the notification unreliable in exactly the way that teaches people
    /// to stop trusting it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }

    private func handle(action: String, requestID: String) async {
        guard let store else { return }
        switch action {
        case RequestCopy.Notification.acceptId:
            await store.acceptFromNotification(requestID)
        case RequestCopy.Notification.declineId:
            await store.declineFromNotification(requestID)
        default:
            // A plain tap, or the conflict notification: open to the request
            // rather than deciding anything on the owner's behalf.
            await store.openRequest(requestID)
        }
    }
}
