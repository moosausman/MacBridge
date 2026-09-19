// MacBridge/Sources/MacBridge/Modules/Mail.swift
// Owns: reading and sending mail via Mail.app, using targeted AppleScript.
// There is no public Mail framework — AppleScript is Apple's own sanctioned
// integration point for this app.

import Foundation

enum Mail {

    /// Delegates to AppleScriptRunner: main-thread execution with a
    /// wall-clock timeout. This used to call
    /// `NSAppleScript.executeAndReturnError` directly on the request's
    /// background thread with no timeout, which could hang forever and --
    /// because Server.swift serialises UI routes behind `uiLock` -- take
    /// every other UI route down with it. See AppleScriptRunner.
    /// 60s rather than the shared 20s default. Reading a message's
    /// properties costs an Apple Event round trip each (~0.4s measured
    /// against a 26k-message inbox), so a 50-message list legitimately
    /// needs ~20s and would otherwise trip the default ceiling.
    ///
    /// Safe to be this generous specifically because /mail/ is NOT one of
    /// Server.swift's `isUI` routes: a slow Mail call occupies its own
    /// client slot but never holds `uiLock`, so it cannot block the
    /// mouse/keyboard/accessibility routes the way a wedged Safari call
    /// could.
    private static func runScript(_ source: String) -> Result<String?, ScriptError> {
        AppleScriptRunner.runForString(source, timeout: 60, appName: "Mail")
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// args: { "limit": Int? (default 20) } — most recent messages in the inbox.
    static func list(args: [String: Any]) -> [String: Any] {
        // Clamp rather than trust: `limit` arrives as unvalidated JSON and
        // went straight into the script below, so a negative or absurd
        // value produced a nonsense AppleScript range.
        //
        // The ceiling is 50 because this costs
        // roughly 0.2s PER MESSAGE and the client's default timeout is 20s.
        //
        // That per-message cost is inherent: reading `subject of m` inside
        // the loop is one Apple Event round trip each. The obvious fix --
        // bulk column reads, `set subjectList to subject of msgs` -- does
        // not work here and was tried: `inbox` is the unified mailbox, so
        // the range resolves to specifiers spanning several accounts'
        // mailboxes and Mail answers "Can't get subject of {message id N of
        // mailbox ...}". Reading per message is what actually works against
        // a unified inbox, so the limit is bounded to match instead.
        //
        // Separately: `messages 1 thru N` raises "Can't get message N of
        // inbox" whenever the inbox holds fewer than N messages, so a nearly
        // empty mailbox errored instead of returning what was there.
        // Clamping against the real count makes the range always valid.
        let limit = max(1, min(args["limit"] as? Int ?? 20, 50))

        let script = """
        tell application "Mail"
            set output to ""
            set n to count of messages of inbox
            if n is 0 then return ""
            set upperBound to \(limit)
            if upperBound > n then set upperBound to n
            repeat with i from 1 to upperBound
                set m to message i of inbox
                set output to output & (subject of m) & "@@@" & (sender of m) & "@@@" & ¬
                    ((date received of m) as string) & "@@@" & (read status of m as string) & "###"
            end repeat
            return output
        end tell
        """

        switch runScript(script) {
        case .failure(let scriptError):
            return ["ok": false, "error": scriptError.message]
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
        let limit = max(1, min(args["limit"] as? Int ?? 20, 50))

        // `whose` is the real fix here, and it's a large one.
        //
        // The old version did `set msgs to messages of inbox` and then read
        // `subject of m` for EVERY message in the mailbox just to test the
        // match -- one Apple Event round trip each. Against the 26k-message
        // inbox this was measured on, at ~0.2s per message, that is well
        // over an hour, holding one of Server.swift's 16 client slots the
        // entire time. It could never have returned within any timeout.
        //
        // A `whose` clause is evaluated inside Mail and returns only the
        // matches, so the expensive per-message reads below run over a
        // handful of results rather than the whole mailbox. (Reading them
        // per message rather than as bulk columns is deliberate -- see
        // list() for why bulk reads fail against the unified inbox.)
        let script = """
        tell application "Mail"
            set output to ""
            set matches to (messages of inbox whose subject contains "\(escape(query))")
            set matchCount to count of matches
            if matchCount is 0 then return ""
            set upperBound to \(limit)
            if upperBound > matchCount then set upperBound to matchCount
            repeat with i from 1 to upperBound
                set m to item i of matches
                set output to output & (subject of m) & "@@@" & (sender of m) & "@@@" & ¬
                    ((date received of m) as string) & "###"
            end repeat
            return output
        end tell
        """

        switch runScript(script) {
        case .failure(let scriptError):
            return ["ok": false, "error": scriptError.message]
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
        case .failure(let scriptError): return ["ok": false, "error": scriptError.message]
        }
    }
}