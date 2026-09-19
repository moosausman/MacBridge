// MacBridge/Sources/MacBridge/Modules/Safari.swift
// Owns: controlling/querying Safari via targeted AppleScript, same pattern
// as Music.swift and System.swift.

import Foundation

enum Safari {

    private static func runScript(_ source: String) -> Result<String?, String> {
        guard let appleScript = NSAppleScript(source: source) else {
            return .failure("Failed to parse internal script")
        }
        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown Safari error"
            return .failure(message)
        }
        return .success(result.stringValue)
    }

    /// Escapes a string for safe use inside an *AppleScript* string literal
    /// (same approach Shell.swift uses) so URLs containing quotes or
    /// backslashes can't break out of the {URL:"..."} literal below.
    private static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// args: { "url": String }  — opens a new tab with the given URL.
    static func openURL(args: [String: Any]) -> [String: Any] {
        guard let urlString = args["url"] as? String, !urlString.isEmpty else {
            return ["ok": false, "error": "'url' is required"]
        }
        guard URL(string: urlString) != nil else {
            return ["ok": false, "error": "'url' is not a valid URL"]
        }

        let escapedURL = escapeForAppleScript(urlString)
        let script = """
tell application "Safari"
    activate
    if (count of windows) = 0 then
        make new document
    end if
    tell window 1 to set current tab to (make new tab with properties {URL:"\(escapedURL)"})
end tell
"""
        switch runScript(script) {
        case .success: return ["ok": true, "url": urlString]
        case .failure(let message): return ["ok": false, "error": message]
        }
    }

    /// args: none — lists open tabs across all windows.
    static func listTabs(args: [String: Any]) -> [String: Any] {
        let script = """
        tell application "Safari"
            set output to ""
            repeat with w in windows
                repeat with t in tabs of w
                    set output to output & (name of t) & "@@@" & (URL of t) & "###"
                end repeat
            end repeat
            return output
        end tell
        """

        switch runScript(script) {
        case .failure(let message):
            return ["ok": false, "error": message]
        case .success(let value):
            guard let value, !value.isEmpty else {
                return ["ok": true, "tabs": []]
            }
            let tabs = value.components(separatedBy: "###")
                .filter { !$0.isEmpty }
                .compactMap { entry -> [String: Any]? in
                    let parts = entry.components(separatedBy: "@@@")
                    guard parts.count == 2 else { return nil }
                    return ["title": parts[0], "url": parts[1]]
                }
            return ["ok": true, "tabs": tabs]
        }
    }

    /// args: none — returns the URL and title of the frontmost tab.
    static func currentTab(args: [String: Any]) -> [String: Any] {
        let script = """
        tell application "Safari"
            set t to current tab of front window
            return (name of t) & "@@@" & (URL of t)
        end tell
        """

        switch runScript(script) {
        case .failure(let message):
            return ["ok": false, "error": message]
        case .success(let value):
            guard let value else {
                return ["ok": false, "error": "No frontmost Safari tab"]
            }
            let parts = value.components(separatedBy: "@@@")
            guard parts.count == 2 else {
                return ["ok": false, "error": "Unexpected response from Safari"]
            }
            return ["ok": true, "title": parts[0], "url": parts[1]]
        }
    }
}