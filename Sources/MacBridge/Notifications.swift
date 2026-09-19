// MacBridge/Sources/MacBridge/Modules/Notifications.swift
// Owns: UserNotifications framework.
// Exposes static functions returning JSON-safe [String: Any] dictionaries.
// Knows nothing about HTTP — Router.swift is the only caller.
//
// NOTE: UNUserNotificationCenter requires the process to run inside a real
// app bundle (CFBundleIdentifier set) — see Info.plist / build.sh. Calling
// this from a bare command-line binary throws an uncaught NSException.

import Foundation
import UserNotifications

enum Notifications {

    static func requestAccess(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            completion(granted)
        }
    }

    /// args: { "title": String, "body": String?, "delaySeconds": Double? (default 1) }
    static func send(args: [String: Any]) -> [String: Any] {
        guard let title = args["title"] as? String, !title.isEmpty else {
            return ["ok": false, "error": "'title' is required"]
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = args["body"] as? String ?? ""
        content.sound = .default

        let delay = (args["delaySeconds"] as? Double) ?? 1.0
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(delay, 0.1), repeats: false)

        let requestId = UUID().uuidString
        let request = UNNotificationRequest(identifier: requestId, content: content, trigger: trigger)

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var dispatchError: Error?

        UNUserNotificationCenter.current().add(request) { error in
            lock.lock(); dispatchError = error; lock.unlock()
            semaphore.signal()
        }

        // Bounded wait. This was a bare semaphore.wait() -- every other
        // blocking wait in this codebase carries a timeout, and this one
        // didn't. A notification centre that never calls back (it lives in
        // another process, and does get wedged) would hold one of
        // Server.swift's 16 client slots and its thread forever, with no
        // way to reclaim either short of restarting MacBridge.
        //
        // Timing out here doesn't cancel the request -- the banner may
        // still appear -- so the response says so rather than claiming
        // failure.
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            return ["ok": false, "id": requestId,
                    "error": "Notification centre did not respond within 10s. "
                           + "The notification may still be delivered; this call "
                           + "stopped waiting for confirmation."]
        }

        lock.lock()
        let failure = dispatchError
        lock.unlock()

        if let failure {
            return ["ok": false, "error": "Failed to schedule notification: \(failure.localizedDescription)"]
        }
        return ["ok": true, "id": requestId]
    }
}
