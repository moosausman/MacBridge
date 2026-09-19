import Foundation
import AppKit
import ApplicationServices

/// Native UI automation, using the user's already-linked WhatsApp session.
/// No chat database access, private protocol, or brittle message DOM selectors.
enum WhatsAppModule {
    private static let knownBundles = ["net.whatsapp.WhatsApp", "com.whatsapp.WhatsApp"]
    private static func installedURL() -> URL? {
        PowerSupport.main {
            for id in knownBundles {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
            }
            for path in ["/Applications/WhatsApp.app", NSHomeDirectory() + "/Applications/WhatsApp.app"] {
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: path),
                   let id = Bundle(url: url)?.bundleIdentifier, knownBundles.contains(id) { return url }
            }
            return nil
        }
    }
    private static func running() throws -> NSRunningApplication {
        let apps = knownBundles.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        guard apps.count == 1, let app = apps.first else {
            throw PowerError.message("Open the native WhatsApp app and sign in first. Use /whatsapp/open; web fallback uses /ui tools with your browser's bundleId")
        }
        return app
    }
    static func status(args: [String: Any]) -> [String: Any] {
        let app = try? running()
        return ["ok": true, "installed": installedURL() != nil, "running": app != nil,
                "pid": app.map { Int($0.processIdentifier) } as Any? ?? NSNull(),
                "bundleId": app?.bundleIdentifier as Any? ?? NSNull(),
                "accessibility": AXIsProcessTrusted(), "loginState": "unknown; inspect /whatsapp/read for login screen"]
    }
    private static func phone(_ args: [String: Any]) throws -> String {
        let raw = try PowerSupport.text(args, "phone", max: 40)
        guard raw.allSatisfy({ "0123456789+()- ".contains($0) }) else {
            throw PowerError.message("phone must contain a full international number")
        }
        let digits = raw.filter { "0123456789".contains($0) }
        guard (7...15).contains(digits.count), digits.first != "0" else {
            throw PowerError.message("Use country code plus number, without a leading local zero, e.g. +14165551234")
        }
        return digits
    }
    static func open(args: [String: Any], chat: Bool = false) -> [String: Any] {
        PowerSupport.result {
            let mode = args["mode"] as? String ?? "auto"
            guard ["auto", "app", "web"].contains(mode) else { throw PowerError.message("mode must be auto, app, or web") }
            let number = try (chat ? phone(args) : nil)
            let message: String?
            if let raw = args["text"] {
                guard let value = raw as? String, value.count <= 8000 else { throw PowerError.message("text must contain at most 8000 characters") }
                message = value
            } else { message = nil }
            let appURL = installedURL(), useNative = mode != "web" && appURL != nil
            if mode == "app" && appURL == nil { throw PowerError.message("Native WhatsApp is not installed") }
            var components = URLComponents()
            if useNative {
                components.scheme = "whatsapp"; components.host = "send"
            } else {
                components.scheme = "https"; components.host = "web.whatsapp.com"
                components.path = chat ? "/send" : "/"
            }
            var items: [URLQueryItem] = []
            if let number { items.append(URLQueryItem(name: "phone", value: number)) }
            if let message { items.append(URLQueryItem(name: "text", value: message)) }
            if !items.isEmpty { components.queryItems = items }
            guard let url = components.url else { throw PowerError.message("Could not construct chat URL") }
            let box = PowerReplyBox()
            PowerSupport.main {
                if useNative, let appURL {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    let completion: (NSRunningApplication?, Error?) -> Void = { app, error in
                        box.finish(["ok": error == nil && app != nil, "opened": app != nil,
                                    "mode": "app", "sent": false, "draftVerified": false,
                                    "note": "App accepted the launch request. Inspect /whatsapp/read to verify the chat and draft",
                                    "error": error?.localizedDescription as Any? ?? NSNull()])
                    }
                    if chat { NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration, completionHandler: completion) }
                    else { NSWorkspace.shared.openApplication(at: appURL, configuration: configuration, completionHandler: completion) }
                } else {
                    let opened = NSWorkspace.shared.open(url)
                    box.finish(["ok": opened, "opened": opened, "mode": "web", "sent": false, "draftVerified": false,
                                "note": "Opened WhatsApp Web in your default browser. Login/link if needed, then use /ui/snapshot with that browser bundleId"])
                }
            }
            return box.wait(seconds: 10)
        }
    }
    static func read(args: [String: Any]) -> [String: Any] {
        PowerSupport.result {
            let app = try running()
            var scoped = args; scoped["pid"] = Int(app.processIdentifier)
            var result = AccessibilityModule.snapshot(args: scoped)
            result["mode"] = "app"
            result["note"] = "Only currently exposed UI is available. Scroll and re-read for more; do not infer message sender/timestamp unless explicitly exposed"
            return result
        }
    }
    static func search(args: [String: Any]) -> [String: Any] {
        PowerSupport.result {
            try PowerSupport.trusted()
            let app = try running(), query = try PowerSupport.text(args, "query", max: 1000)
            let id = try PowerSupport.text(args, "searchElementId")
            let field = try AccessibilityModule.entry(id)
            guard field.pid == app.processIdentifier else { throw PowerError.message("Search element belongs to another app") }
            guard ["AXTextField", "AXSearchField", "AXTextArea"].contains(AccessibilityModule.string(field.element, kAXRoleAttribute) ?? "") else {
                throw PowerError.message("Select the search field from /whatsapp/read")
            }
            try PowerSupport.activate(app)
            try AccessibilityModule.setText(field, text: query)
            return ["ok": true, "query": query, "note": "Search text verified. Refresh /whatsapp/read, inspect matching chats, and open the correct result using its AX action"]
        }
    }
    /// The caller must choose the conversation header, not a matching sidebar row.
    /// Exact labels alone cannot disambiguate duplicate contact display names.
    private static func context(_ args: [String: Any]) throws -> (NSRunningApplication, AccessibilityModule.Entry, AccessibilityModule.Entry) {
        try PowerSupport.trusted()
        let app = try running()
        let header = try AccessibilityModule.entry(PowerSupport.text(args, "headerElementId"))
        let editor = try AccessibilityModule.entry(PowerSupport.text(args, "editorElementId"))
        let recipient = try PowerSupport.text(args, "expectedRecipient", max: 500)
        guard header.pid == app.processIdentifier, editor.pid == app.processIdentifier else {
            throw PowerError.message("Elements must belong to the native WhatsApp app")
        }
        guard Date().timeIntervalSince(header.created) < 30, Date().timeIntervalSince(editor.created) < 30 else {
            throw PowerError.message("Get a fresh WhatsApp snapshot before preparing or sending a message (30 second limit)")
        }
        let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap {
            AccessibilityModule.string(header.element, $0)
        }
        guard labels.contains(recipient) else { throw PowerError.message("Conversation header no longer matches expectedRecipient") }
        guard ["AXTextArea", "AXTextField"].contains(AccessibilityModule.string(editor.element, kAXRoleAttribute) ?? "") else {
            throw PowerError.message("editorElementId must identify the message composer")
        }
        guard let headerWindow = AccessibilityModule.elementAttribute(header.element, kAXWindowAttribute),
              let editorWindow = AccessibilityModule.elementAttribute(editor.element, kAXWindowAttribute),
              CFEqual(headerWindow, editorWindow) else { throw PowerError.message("Header and composer must belong to the same window") }
        try PowerSupport.activate(app)
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = AccessibilityModule.elementAttribute(root, kAXFocusedWindowAttribute), CFEqual(focused, editorWindow) else {
            throw PowerError.message("The selected conversation window is no longer focused")
        }
        return (app, header, editor)
    }
    static func draft(args: [String: Any]) -> [String: Any] {
        PowerSupport.result {
            let text = try PowerSupport.text(args, "text")
            let (app, _, editor) = try context(args)
            try PowerSupport.ensureFrontmost(app.processIdentifier)
            try AccessibilityModule.setText(editor, text: text)
            return ["ok": true, "draftVerified": true, "sent": false, "note": "Refresh /whatsapp/read before sending"]
        }
    }
    static func send(args: [String: Any]) -> [String: Any] {
        PowerSupport.result {
            let expectedText = try PowerSupport.text(args, "expectedText")
            let send = try AccessibilityModule.entry(PowerSupport.text(args, "sendElementId"))
            let (app, header, editor) = try context(args)
            guard send.pid == app.processIdentifier, Date().timeIntervalSince(send.created) < 30,
                  AccessibilityModule.string(send.element, kAXRoleAttribute) == "AXButton",
                  AccessibilityModule.actions(send.element).contains(kAXPressAction) else {
                throw PowerError.message("Choose the current Send button from a fresh WhatsApp snapshot")
            }
            let expectedLabel = args["expectedSendLabel"] as? String ?? "Send"
            let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].compactMap {
                AccessibilityModule.string(send.element, $0)
            }
            guard labels.contains(expectedLabel) else { throw PowerError.message("Send button label changed; inspect it and pass its exact expectedSendLabel") }
            guard let window = AccessibilityModule.elementAttribute(send.element, kAXWindowAttribute),
                  let editorWindow = AccessibilityModule.elementAttribute(editor.element, kAXWindowAttribute), CFEqual(window, editorWindow) else {
                throw PowerError.message("Send button and composer belong to different windows")
            }
            guard AccessibilityModule.string(editor.element, kAXValueAttribute) == expectedText else {
                throw PowerError.message("Composer text does not exactly match expectedText; nothing was sent")
            }
            // Recheck the header immediately before the side effect.
            let recipient = try PowerSupport.text(args, "expectedRecipient")
            guard [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].contains(where: {
                AccessibilityModule.string(header.element, $0) == recipient
            }) else { throw PowerError.message("Conversation changed; nothing was sent") }
            try PowerSupport.ensureFrontmost(app.processIdentifier)
            try AccessibilityModule.check(AXUIElementPerformAction(send.element, kAXPressAction as CFString), "Press Send")
            return ["ok": true, "sendInvoked": true, "deliveryVerified": false,
                    "note": "Pressed the observed Send button once. Inspect the conversation for the outgoing message. Never automatically retry an uncertain send"]
        }
    }
}
