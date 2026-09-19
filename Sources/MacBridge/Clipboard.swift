// MacBridge/Sources/MacBridge/Modules/Clipboard.swift
// Owns: AppKit's NSPasteboard.
// Exposes static functions returning JSON-safe [String: Any] dictionaries.
// Knows nothing about HTTP — Router.swift is the only caller.
//
// NOTE: NSPasteboard is part of AppKit and requires a GUI-session process
// (which an .app bundle launched via `open` provides). Clipboard access
// does not require a TCC permission prompt.

import Foundation
import AppKit

enum Clipboard {

    /// No args. Returns the current clipboard contents as plain text, if any.
    static func get(args: [String: Any]) -> [String: Any] {
        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string) else {
            return ["ok": true, "text": NSNull()]
        }
        return ["ok": true, "text": text]
    }

    /// args: { "text": String }
    static func set(args: [String: Any]) -> [String: Any] {
        guard let text = args["text"] as? String else {
            return ["ok": false, "error": "'text' is required"]
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let success = pasteboard.setString(text, forType: .string)

        guard success else {
            return ["ok": false, "error": "Failed to write to clipboard"]
        }
        return ["ok": true]
    }
}
