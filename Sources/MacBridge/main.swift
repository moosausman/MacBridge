// MacBridge/Sources/MacBridge/main.swift
// Build & run: ./build.sh   (builds MacBridge.app and launches it)
// Listens on http://localhost:8765
//
// This file bootstraps permissions and starts the server. Individual feature
// operations remain owned by Modules/*.swift.

import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

// ── Automation permission targets ─────────────────────────────────────────
// Automation permission is granted separately for every application that
// MacBridge controls through Apple Events.
private struct AutomationTarget {
    let name: String
    let bundleIdentifier: String
}

private let automationTargets = [
    AutomationTarget(name: "Safari", bundleIdentifier: "com.apple.Safari"),
    AutomationTarget(name: "Mail", bundleIdentifier: "com.apple.mail"),
    AutomationTarget(name: "Finder", bundleIdentifier: "com.apple.finder"),
    AutomationTarget(name: "Terminal", bundleIdentifier: "com.apple.Terminal"),
    AutomationTarget(name: "System Events", bundleIdentifier: "com.apple.systemevents"),
    AutomationTarget(name: "System Settings", bundleIdentifier: "com.apple.systempreferences"),
]

private func requestAutomationPermission(for target: AutomationTarget) {
    let descriptor = NSAppleEventDescriptor(
        bundleIdentifier: target.bundleIdentifier
    )

    let status = AEDeterminePermissionToAutomateTarget(
        descriptor.aeDesc,
        AEEventClass(typeWildCard),
        AEEventID(typeWildCard),
        true
    )

    switch status {
    case noErr:
        print("✅ \(target.name) Automation access granted")
    case OSStatus(errAEEventNotPermitted):
        print("❌ \(target.name) Automation access denied")
    default:
        print("⚠️ \(target.name) Automation status: \(status)")
    }
}

private func requestAccessibilityPermission() {
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [promptKey: true] as CFDictionary
    let granted = AXIsProcessTrustedWithOptions(options)

    print(
        granted
            ? "✅ Accessibility access granted"
            : "⚠️ Accessibility permission requested; approve it in System Settings"
    )
}

private func requestScreenRecordingPermission() {
    if CGPreflightScreenCaptureAccess() {
        print("✅ Screen Recording access granted")
        return
    }

    let granted = CGRequestScreenCaptureAccess()
    print(
        granted
            ? "✅ Screen Recording access granted"
            : "❌ Screen Recording access denied"
    )
}

// ── Permission bootstrapper ────────────────────────────────────────────────
// Framework permissions settle first. Automation checks then run sequentially
// on a background queue because each check can block while a prompt is open.
func requestAllPermissions(completion: @escaping () -> Void) {
    let group = DispatchGroup()

    group.enter()
    Calendar_.requestAccess { granted in
        print(granted ? "✅ Calendar access granted" : "❌ Calendar access denied")
        group.leave()
    }

    group.enter()
    Reminders.requestAccess { granted in
        print(granted ? "✅ Reminders access granted" : "❌ Reminders access denied")
        group.leave()
    }

    group.enter()
    ContactsModule.requestAccess { granted in
        print(granted ? "✅ Contacts access granted" : "❌ Contacts access denied")
        group.leave()
    }

    group.enter()
    Notifications.requestAccess { granted in
        print(granted ? "✅ Notifications access granted" : "❌ Notifications access denied")
        group.leave()
    }

    // Do not block the main thread with group.wait(). Permission callbacks
    // need the application's run loop to remain active.
    group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
        for target in automationTargets {
            requestAutomationPermission(for: target)
        }

        requestAccessibilityPermission()
        requestScreenRecordingPermission()

        DispatchQueue.main.async {
            print("✅ MacBridge permissions ready")
            completion()
        }
    }
}

// ── HTTP server ────────────────────────────────────────────────────────────
private var server: MacBridgeServer?

requestAllPermissions {
    server = MacBridgeServer(port: 8765)
    print("🚀 MacBridge running on http://localhost:8765")
    server?.start()
}

signal(SIGINT) { _ in
    print("Shutting down...")
    server?.stop()
    exit(EXIT_SUCCESS)
}

RunLoop.main.run()