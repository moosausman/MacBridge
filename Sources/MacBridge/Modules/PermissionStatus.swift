// MacBridge/Sources/MacBridge/Modules/PermissionStatus.swift
// Owns: reporting (never requesting) every macOS privacy grant MacBridge
// depends on, so Jugnu can check before acting and tell the user exactly
// what to enable instead of failing halfway through a task.
//
//   /permissions/status  {}
//
// Each entry is "granted", "denied", "not_determined", "limited" or
// "unknown", plus where to enable it. Automation (Apple Events) is per
// target app; a target that isn't running reports "unknown" -- macOS can
// only answer for running apps.

import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import EventKit
import Contacts
import UserNotifications

enum PermissionStatusModule {

    private static let settingsPath = "System Settings > Privacy & Security"

    private static let targets = [("Finder", "com.apple.finder"), ("System Events", "com.apple.systemevents"),
                                  ("Terminal", "com.apple.Terminal"), ("Safari", "com.apple.Safari"),
                                  ("Mail", "com.apple.mail"), ("Notes", "com.apple.Notes"),
                                  ("Music", "com.apple.Music"), ("Spotify", "com.spotify.client")]

    private static func eventKit(_ type: EKEntityType) -> String {
        let status = EKEventStore.authorizationStatus(for: type)
        switch status {
        case .notDetermined: return "not_determined"
        case .restricted, .denied: return "denied"
        case .authorized: return "granted"
        default:
            // .fullAccess / .writeOnly exist from macOS 14.
            if #available(macOS 14.0, *) {
                if status == .fullAccess { return "granted" }
                if status == .writeOnly { return "limited" }
            }
            return "unknown"
        }
    }

    private static func contacts() -> String {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: return "not_determined"
        case .restricted, .denied: return "denied"
        case .authorized: return "granted"
        default: return "limited"
        }
    }

    private static func notifications() -> String {
        let box = PowerReplyBox()
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let s: String
            switch settings.authorizationStatus {
            case .authorized, .provisional: s = "granted"
            case .denied: s = "denied"
            case .notDetermined: s = "not_determined"
            default: s = "unknown"
            }
            box.finish(["status": s])
        }
        return box.wait(seconds: 3)["status"] as? String ?? "unknown"
    }

    private static func automation(_ bundleId: String) -> String {
        let running = PowerSupport.main {
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
        }
        guard running else { return "unknown" }
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleId)
        let status = AEDeterminePermissionToAutomateTarget(descriptor.aeDesc, AEEventClass(typeWildCard),
                                                           AEEventID(typeWildCard), false)
        switch status {
        case noErr: return "granted"
        case OSStatus(errAEEventNotPermitted): return "denied"
        case -1744: return "not_determined"  // errAEEventWouldRequireUserConsent
        default: return "unknown"
        }
    }

    private static func fullDiskAccess() -> String {
        // A protected file every account has; readable only with Full Disk Access.
        let probe = ("~/Library/Safari/Bookmarks.plist" as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: probe) else { return "unknown" }
        return FileManager.default.isReadableFile(atPath: probe) && (try? Data(contentsOf: URL(fileURLWithPath: probe))) != nil
            ? "granted" : "denied"
    }

    static func status(args: [String: Any]) -> [String: Any] {
        let axGranted = PowerSupport.main { AXIsProcessTrusted() }
        var entries: [String: [String: Any]] = [
            "accessibility": ["status": axGranted ? "granted" : "denied",
                              "where": "\(settingsPath) > Accessibility",
                              "needed_for": "keyboard, mouse, windows, reading app interfaces"],
            "screen_recording": ["status": CGPreflightScreenCaptureAccess() ? "granted" : "denied",
                                 "where": "\(settingsPath) > Screen Recording",
                                 "needed_for": "screenshots and reading text on screen (OCR)"],
            "calendar": ["status": eventKit(.event), "where": "\(settingsPath) > Calendars",
                         "needed_for": "reading and creating calendar events"],
            "reminders": ["status": eventKit(.reminder), "where": "\(settingsPath) > Reminders",
                          "needed_for": "reading and creating reminders"],
            "contacts": ["status": contacts(), "where": "\(settingsPath) > Contacts",
                         "needed_for": "looking people up"],
            "notifications": ["status": notifications(), "where": "System Settings > Notifications > MacBridge",
                              "needed_for": "timers and alerts"],
            "full_disk_access": ["status": fullDiskAccess(), "where": "\(settingsPath) > Full Disk Access",
                                 "needed_for": "Safari history and Mail data files (optional)"],
        ]
        var automationTargets: [String: String] = [:]
        for (name, bundle) in targets { automationTargets[name] = automation(bundle) }
        entries["automation"] = ["status": automationTargets.values.contains("denied") ? "denied" : "granted_or_unknown",
                                 "where": "\(settingsPath) > Automation > MacBridge",
                                 "targets": automationTargets,
                                 "needed_for": "AppleScript control of each app (unknown = app not running)"]
        let missing = entries.filter { ["denied", "not_determined"].contains($0.value["status"] as? String ?? "") }
            .map { $0.key }.sorted()
        return ["ok": true, "permissions": entries, "missing": missing,
                "user": NSUserName(), "session_port": listenPort]
    }

    // MARK: - Asking

    /// Asks macOS for every grant MacBridge uses, in whichever login this
    /// instance runs, and reports the result.
    ///
    ///   /permissions/request  {}
    ///
    /// Meant to run while someone is looking at that login's screen. Calendar,
    /// Reminders, Contacts and each app under Automation have no "+" button in
    /// System Settings: an app only appears there after it asks, and a request
    /// made while nobody is watching (the Jugnu account running in the
    /// background) is never answered. Each prompt gets up to two minutes.
    /// Accessibility and Screen Recording open System Settings, where the
    /// switch is turned on by hand.
    static func request(args: [String: Any]) -> [String: Any] {
        var asked: [String] = []
        func waitFor(_ start: (@escaping () -> Void) -> Void) {
            let done = DispatchSemaphore(value: 0)
            start { done.signal() }
            _ = done.wait(timeout: .now() + 120)
        }

        let store = EKEventStore()
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            asked.append("calendar")
            waitFor { finish in store.requestFullAccessToEvents { _, _ in finish() } }
        }
        if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
            asked.append("reminders")
            waitFor { finish in store.requestFullAccessToReminders { _, _ in finish() } }
        }
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            asked.append("contacts")
            waitFor { finish in CNContactStore().requestAccess(for: .contacts) { _, _ in finish() } }
        }
        if notifications() == "not_determined" {
            asked.append("notifications")
            waitFor { finish in
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in finish() }
            }
        }

        // Automation is asked per app, and macOS only asks about apps that are
        // running -- so each installed one is started hidden first.
        for (name, bundleId) in targets {
            guard let url = PowerSupport.main({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) })
            else { continue }
            if automation(bundleId) == "unknown" {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.hides = true
                PowerSupport.main { NSWorkspace.shared.openApplication(at: url, configuration: configuration) }
                let deadline = Date().addingTimeInterval(10)
                while automation(bundleId) == "unknown" && Date() < deadline { usleep(300_000) }
            }
            guard ["not_determined", "unknown"].contains(automation(bundleId)) else { continue }
            asked.append("automation:\(name)")
            waitFor { finish in
                DispatchQueue.global().async {
                    let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
                    _ = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard),
                                                              AEEventID(typeWildCard), true)
                    finish()
                }
            }
        }

        if !PowerSupport.main({ AXIsProcessTrusted() }) {
            asked.append("accessibility")
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = PowerSupport.main { AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) }
        }
        if !CGPreflightScreenCaptureAccess() {
            asked.append("screen_recording")
            _ = PowerSupport.main { CGRequestScreenCaptureAccess() }
        }

        var result = status(args: args)
        result["asked"] = asked
        result["note"] = "Screen Recording takes effect after MacBridge restarts. Accessibility and Screen "
            + "Recording are switched on in System Settings; as a Standard account, macOS asks for an "
            + "administrator's name and password there."
        return result
    }
}
