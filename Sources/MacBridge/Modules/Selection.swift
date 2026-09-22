// MacBridge/Sources/MacBridge/Modules/Selection.swift
// Owns: reading the text the user has selected in the frontmost app, for
// Jugnu's "ask about the selection" shortcut.
//
//   /ui/selection { copyFallback?: Bool = true }  ->  { ok, text, app, bundleId, via }
//
// Accessibility first: the focused element's selected text, which most
// native apps expose. Apps that don't (Chrome, Electron apps) are read by
// copying the selection with Cmd-C -- and the clipboard is put back exactly
// as it was afterwards, so the user never notices.

import Foundation
import AppKit
import ApplicationServices

enum SelectionModule {

    static func selection(args: [String: Any]) -> [String: Any] {
        PowerSupport.result {
            try PowerSupport.trusted()
            let front = PowerSupport.main { NSWorkspace.shared.frontmostApplication }
            guard let app = front else { throw PowerError.message("No app is in front") }
            var text = ""
            var via = "accessibility"

            // If Accessibility can answer -- even "nothing selected" -- trust
            // it: that's instant and sends nothing to the app. Only apps that
            // can't say (Chrome, Electron) get the Cmd-C fallback.
            var accessibilityAnswered = false
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            if let focused = AccessibilityModule.elementAttribute(axApp, kAXFocusedUIElementAttribute) {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &value) == .success {
                    accessibilityAnswered = true
                    text = (value as? String) ?? ""
                }
            }
            if !accessibilityAnswered && (args["copyFallback"] as? Bool ?? true) {
                text = copySelection()
                via = "copy"
            }
            return ["ok": true, "text": text, "app": app.localizedName ?? "", "bundleId": app.bundleIdentifier ?? "",
                    "via": text.isEmpty ? "none" : via]
        }
    }

    /// Cmd-C into the frontmost app, read what it copied, then restore the
    /// clipboard to exactly what it held before.
    private static func copySelection() -> String {
        let pasteboard = NSPasteboard.general
        let saved: [NSPasteboardItem] = PowerSupport.main {
            (pasteboard.pasteboardItems ?? []).map { item in
                let copy = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) { copy.setData(data, forType: type) }
                }
                return copy
            }
        }
        let before = PowerSupport.main { pasteboard.changeCount }
        _ = Keyboard.pressKey(args: ["key": "c", "modifiers": ["cmd"]])

        var copied = ""
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            usleep(40_000)
            if PowerSupport.main({ pasteboard.changeCount }) != before {
                usleep(40_000)
                copied = PowerSupport.main { pasteboard.string(forType: .string) } ?? ""
                break
            }
        }
        if PowerSupport.main({ pasteboard.changeCount }) != before {
            PowerSupport.main {
                pasteboard.clearContents()
                if !saved.isEmpty { pasteboard.writeObjects(saved) }
            }
        }
        return copied
    }
}
