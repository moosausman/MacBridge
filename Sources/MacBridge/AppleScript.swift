// MacBridge/Sources/MacBridge/Modules/AppleScript.swift
// Owns: NSAppleScript (arbitrary AppleScript execution).
// Exposes static functions returning JSON-safe [String: Any] dictionaries.
// Knows nothing about HTTP — Router.swift is the only caller.
//
// ⚠️ No sandboxing or guardrail here by design — this runs whatever script
// text is sent, with full user privileges. Anyone who can reach this HTTP
// server can run arbitrary AppleScript on this Mac. Acceptable only because
// the server binds to localhost. Do not expose this port beyond localhost.

import Foundation

enum AppleScriptModule {

    /// args: { "script": String }
    static func run(args: [String: Any]) -> [String: Any] {
        guard let source = args["script"] as? String, !source.isEmpty else {
            return ["ok": false, "error": "'script' is required"]
        }

        guard let appleScript = NSAppleScript(source: source) else {
            return ["ok": false, "error": "Failed to parse script"]
        }

        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            return ["ok": false, "error": message]
        }

        // NSAppleEventDescriptor doesn't map cleanly to JSON; surface what
        // we reasonably can as a string, and the raw description as a
        // fallback for debugging.
        return [
            "ok": true,
            "result": result.stringValue ?? NSNull()
        ]
    }
}