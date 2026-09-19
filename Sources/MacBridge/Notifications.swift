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
        var dispatchError: Error?

        UNUserNotificationCenter.current().add(request) { error in
            dispatchError = error
            semaphore.signal()
        }

        semaphore.wait()

        if let dispatchError {
            return ["ok": false, "error": "Failed to schedule notification: \(dispatchError.localizedDescription)"]
        }
        return ["ok": true, "id": requestId]
    }
}
