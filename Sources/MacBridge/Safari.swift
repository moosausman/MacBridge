// MacBridge/Sources/MacBridge/Modules/Safari.swift
// Owns: controlling/querying Safari via targeted AppleScript, same pattern
// as Music.swift and System.swift.

import Foundation

enum Safari {

    /// Delegates to AppleScriptRunner: main-thread execution with a
    /// wall-clock timeout. This used to call
    /// `NSAppleScript.executeAndReturnError` directly on the request's
    /// background thread with no timeout, which could hang forever and --
    /// because Server.swift serialises UI routes behind `uiLock` -- take
    /// every other UI route down with it. See AppleScriptRunner.
    private static func runScript(_ source: String) -> Result<String?, ScriptError> {
        AppleScriptRunner.runForString(source, appName: "Safari")
    }

    /// Escapes a string for safe use inside an *AppleScript* string literal
    /// (same approach Shell.swift uses) so URLs containing quotes or
    /// backslashes can't break out of the {URL:"..."} literal below.
    private static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// args: { "url": String, "background": Bool? (default true) }
    ///
    /// Opens a tab in the BACKGROUND by default: Safari is not activated and
    /// the new tab is not made current, so whatever the user is doing keeps
    /// focus and nothing appears in front of them.
    ///
    /// This used to unconditionally `activate` Safari and `set current tab`,
    /// so any lookup the assistant did mid-task yanked the user out of
    /// whatever they were working on. Opening a page for later reference and
    /// demanding the user look at it right now are different intentions, and
    /// only the caller knows which one applies -- so it's an argument, and
    /// the quieter of the two is the default.
    static func openURL(args: [String: Any]) -> [String: Any] {
        guard let urlString = args["url"] as? String, !urlString.isEmpty else {
            return ["ok": false, "error": "'url' is required"]
        }
        guard URL(string: urlString) != nil else {
            return ["ok": false, "error": "'url' is not a valid URL"]
        }

        let background = (args["background"] as? Bool) ?? true
        let escapedURL = escapeForAppleScript(urlString)

        // With no window open there is nothing to add a tab to, and `make new
        // document` unavoidably surfaces Safari. That case is reported rather
        // than pretended about, so "background" never silently lies.
        let script = background ? """
tell application "Safari"
    if (count of windows) = 0 then
        make new document with properties {URL:"\(escapedURL)"}
        return "opened-window"
    else
        tell window 1 to make new tab with properties {URL:"\(escapedURL)"}
        return "opened-background-tab"
    end if
end tell
""" : """
tell application "Safari"
    activate
    if (count of windows) = 0 then
        make new document
    end if
    tell window 1 to set current tab to (make new tab with properties {URL:"\(escapedURL)"})
    return "opened-foreground-tab"
end tell
"""
        switch runScript(script) {
        case .success(let outcome):
            let mode = outcome ?? "opened"
            var result: [String: Any] = ["ok": true, "url": urlString, "outcome": mode]
            result["background"] = (mode == "opened-background-tab")
            if mode == "opened-window" {
                result["note"] = "Safari had no window open, so a new one was created and is "
                               + "visible. A background tab isn't possible with no window to "
                               + "put it in."
            }
            return result
        case .failure(let scriptError):
            return ["ok": false, "error": scriptError.message]
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
        case .failure(let scriptError):
            return ["ok": false, "error": scriptError.message]
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
        case .failure(let scriptError):
            return ["ok": false, "error": scriptError.message]
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