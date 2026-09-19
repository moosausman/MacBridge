// MacBridge/Sources/MacBridge/Modules/Mail.swift
// Owns: reading and sending mail via Mail.app, using targeted AppleScript.
// There is no public Mail framework — AppleScript is Apple's own sanctioned
// integration point for this app.

import Foundation

enum Mail {

    private static func runScript(_ source: String) -> Result<String?, String> {
        guard let appleScript = NSAppleScript(source: source) else {
            return .failure("Failed to parse internal script")
        }
        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown Mail error"
            return .failure(message)
        }
        return .success(result.stringValue)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// args: { "limit": Int? (default 20) } — most recent messages in the inbox.
    static func list(args: [String: Any]) -> [String: Any] {
        let limit = args["limit"] as? Int ?? 20

        let script = """
        tell application "Mail"
            set output to ""
            set msgs to messages 1 thru \(limit) of inbox
            repeat with m in msgs
                set output to output & (subject of m) & "@@@" & (sender of m) & "@@@" & ¬
                    ((date received of m) as string) & "@@@" & (read status of m as string) & "###"
            end repeat
            return output
        end tell
        """

        switch runScript(script) {
        case .failure(let message):
            return ["ok": false, "error": message]
        case .success(let value):
            guard let value, !value.isEmpty else {
                return ["ok": true, "messages": []]
            }
            let messages = value.components(separatedBy: "###")
                .filter { !$0.isEmpty }
                .compactMap { entry -> [String: Any]? in
                    let parts = entry.components(separatedBy: "@@@")
                    guard parts.count == 4 else { return nil }
                    return [
                        "subject": parts[0],
                        "sender": parts[1],
                        "dateReceived": parts[2],
                        "read": parts[3] == "true"
                    ]
                }
            return ["ok": true, "messages": messages]
        }
    }

    /// args: { "query": String, "limit": Int? (default 20) } — searches inbox subjects.
    static func search(args: [String: Any]) -> [String: Any] {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return ["ok": false, "error": "'query' is required"]
        }
        let limit = args["limit"] as? Int ?? 20

        let script = """
        tell application "Mail"
            set output to ""
            set matchCount to 0
            set msgs to messages of inbox
            repeat with m in msgs
                if subject of m contains "\(escape(query))" then
                    set output to output & (subject of m) & "@@@" & (sender of m) & "@@@" & ¬
                        ((date received of m) as string) & "###"
                    set matchCount to matchCount + 1
                    if matchCount ≥ \(limit) then exit repeat
                end if
            end repeat
            return output
        end tell
        """

        switch runScript(script) {
        case .failure(let message):
            return ["ok": false, "error": message]
        case .success(let value):
            guard let value, !value.isEmpty else {
                return ["ok": true, "messages": []]
            }
            let messages = value.components(separatedBy: "###")
                .filter { !$0.isEmpty }
                .compactMap { entry -> [String: Any]? in
                    let parts = entry.components(separatedBy: "@@@")
                    guard parts.count == 3 else { return nil }
                    return ["subject": parts[0], "sender": parts[1], "dateReceived": parts[2]]
                }
            return ["ok": true, "messages": messages]
        }
    }

    /// args: { "to": String, "subject": String, "body": String }
    static func send(args: [String: Any]) -> [String: Any] {
        guard let to = args["to"] as? String, !to.isEmpty else {
            return ["ok": false, "error": "'to' is required"]
        }
        guard let subject = args["subject"] as? String else {
            return ["ok": false, "error": "'subject' is required"]
        }
        guard let body = args["body"] as? String else {
            return ["ok": false, "error": "'body' is required"]
        }

        let script = """
        tell application "Mail"
            set newMessage to make new outgoing message with properties ¬
                {subject:"\(escape(subject))", content:"\(escape(body))", visible:false}
            tell newMessage
                make new to recipient with properties {address:"\(escape(to))"}
                send
            end tell
        end tell
        """

        switch runScript(script) {
        case .success: return ["ok": true, "to": to, "subject": subject]
        case .failure(let message): return ["ok": false, "error": message]
        }
    }
}