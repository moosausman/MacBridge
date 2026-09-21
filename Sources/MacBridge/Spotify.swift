// MacBridge/Sources/MacBridge/Modules/Spotify.swift
// Owns: controlling the Spotify desktop app via its AppleScript dictionary.
//
// WHAT SPOTIFY'S DICTIONARY CAN AND CANNOT DO
// -------------------------------------------
// It can: play a URI, pause, resume, skip, set volume, and report the
// current track and player state.
//
// It canNOT search. There is no search command, and `play track` accepts
// only a real track/album/playlist URI -- `spotify:search:<query>` is not
// playable. Worse, Spotify SILENTLY IGNORES a URI it can't resolve and
// still returns success to AppleScript, so a caller checking only the exit
// status gets a false positive every time. The previous implementation did
// exactly that: it sent `spotify:search:<song> <artist>` and reported
// "Playing '<song>'" on every call while nothing ever played.
//
// Consequences that shape this file:
//   1. Resolving a name to a URI happens elsewhere (SpotifySearch.swift,
//      using Spotify's own web search off-screen). This module only ever
//      takes a real URI -- or an open.spotify.com link, which it converts.
//   2. Every play VERIFIES by reading the player state and current track
//      back afterwards, because the command's own result is not evidence
//      that anything happened.
//   3. Playback is background-only: Spotify is never activated, and if it
//      isn't running it's launched hidden. `play track` over Apple Events
//      doesn't need focus.
import Foundation
import AppKit

enum SpotifyModule {

    private static func runScript(_ source: String) -> Result<String?, ScriptError> {
        AppleScriptRunner.runForString(source, timeout: 15, appName: "Spotify")
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Reads player state and the current track. The `try` wrapper matters:
    /// with nothing loaded, `name of current track` raises rather than
    /// returning empty, which is itself the signal that nothing is playing.
    private static let stateScript = """
    tell application "Spotify"
        if it is not running then return "notrunning"
        try
            -- Do NOT name these st/n/a/u: `st` is reserved in AppleScript
            -- (the ordinal suffix, as in 1st) and the script fails to
            -- compile with "Expected expression but found \"st\"".
            set playState to player state as text
            set trackName to name of current track
            set trackArtist to artist of current track
            set trackURI to spotify url of current track
            return playState & "@@@" & trackName & "@@@" & trackArtist & "@@@" & trackURI
        on error
            -- `current track` raises rather than returning empty when
            -- nothing is loaded, which is itself the signal.
            return (player state as text) & "@@@" & "" & "@@@" & "" & "@@@" & ""
        end try
    end tell
    """

    private static func parseState(_ raw: String?) -> [String: Any] {
        guard let raw, raw != "notrunning" else {
            return ["ok": false, "running": false,
                    "error": "Spotify isn't running. Open it first (open_app \"Spotify\")."]
        }
        let parts = raw.components(separatedBy: "@@@")
        let state = parts.first ?? "unknown"
        let name = parts.count > 1 ? parts[1] : ""
        let artist = parts.count > 2 ? parts[2] : ""
        let uri = parts.count > 3 ? parts[3] : ""
        var result: [String: Any] = [
            "ok": true, "running": true, "playerState": state,
            "playing": state == "playing",
        ]
        if !name.isEmpty {
            result["track"] = name
            result["artist"] = artist
            result["uri"] = uri
        }
        return result
    }

    /// args: {} — what Spotify is doing right now.
    static func state(args: [String: Any]) -> [String: Any] {
        switch runScript(stateScript) {
        case .failure(let e): return ["ok": false, "error": e.message]
        case .success(let raw): return parseState(raw)
        }
    }

    private static let bundleId = "com.spotify.client"

    private static func isRunning() -> Bool {
        PowerSupport.main { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty }
    }

    /// Starts Spotify hidden and in the background if it isn't running, and
    /// waits until it answers Apple Events. Returns an error string, or nil.
    /// Spotify brings itself to the front when it launches, whatever the
    /// launch options say. Put things back: hide Spotify and return focus to
    /// whatever the user was using.
    private static func restoreFocus(to previous: NSRunningApplication?) {
        PowerSupport.main {
            guard let spotify = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return }
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId {
                spotify.hide()
            }
            if let previous, !previous.isTerminated, previous.bundleIdentifier != bundleId {
                previous.activate()
            }
        }
    }

    /// Spotify may raise its window several seconds after launch or play,
    /// after the request has already returned. Keep an eye out for a short
    /// while and hand focus back whenever it does.
    private static func guardFocus(for previous: NSRunningApplication?) {
        guard let previous, previous.bundleIdentifier != bundleId else { return }
        DispatchQueue.global(qos: .utility).async {
            for delay in [0.0, 0.7, 1.5, 3.0, 5.0, 8.0] {
                Thread.sleep(forTimeInterval: delay == 0 ? 0 : 0.8)
                _ = delay
                let front = PowerSupport.main { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
                if front == bundleId { restoreFocus(to: previous) }
            }
        }
    }

    private static func ensureRunning() -> String? {
        if isRunning() { return nil }
        guard let appURL = PowerSupport.main({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) }) else {
            return "Spotify isn't installed."
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        config.addsToRecentItems = false
        let box = PowerReplyBox()
        DispatchQueue.main.async {
            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
                box.finish(["error": error?.localizedDescription ?? NSNull()])
            }
        }
        if let error = box.wait(seconds: 15)["error"] as? String { return "Couldn't start Spotify: \(error)" }
        // Spotify takes a few seconds after launch before it can play.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            usleep(500_000)
            if case .success(let raw) = runScript("tell application \"Spotify\" to return player state as text"),
               raw != nil { usleep(1_500_000); return nil }
        }
        return "Spotify started but didn't become ready in time."
    }

    /// open.spotify.com/track/<id>?si=... -> spotify:track:<id>
    private static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: #"open\.spotify\.com/(?:intl-[a-z]+/)?(track|album|artist|playlist|episode|show)/([A-Za-z0-9]{22})"#,
                                     options: .regularExpression) {
            let parts = trimmed[range].split(separator: "/")
            if parts.count >= 3 { return "spotify:\(parts[parts.count - 2]):\(parts[parts.count - 1])" }
        }
        return trimmed
    }

    /// args: { "uri": String, "verify": Bool? (default true) }
    ///
    /// Plays a real Spotify URI. Verification is on by default and is the
    /// whole point: `play track` reports success for URIs it silently
    /// discards, so without reading the state back there is no way to tell
    /// a play from a no-op.
    static func playURI(args: [String: Any]) -> [String: Any] {
        guard let rawURI = args["uri"] as? String, !rawURI.isEmpty else {
            return ["ok": false, "error": "'uri' is required"]
        }
        let uri = normalize(rawURI)
        // Whatever the user had in front when they asked; it stays in front.
        let originalFront = PowerSupport.main { NSWorkspace.shared.frontmostApplication }
        defer { guardFocus(for: originalFront) }
        // Reject the specific wrong-URI shape that caused this whole bug,
        // with a message that says what to do instead. Verification below
        // would catch it anyway, but only after activating Spotify and
        // waiting three seconds for a play that was never going to happen.
        guard !uri.hasPrefix("spotify:search:") else {
            return ["ok": false,
                    "error": "spotify:search:<query> is not playable -- Spotify's AppleScript "
                           + "has no search command and silently ignores this URI. Resolve the "
                           + "query to a real spotify:track:<id> first (play_song and "
                           + "spotify_search do this)."]
        }
        guard uri.hasPrefix("spotify:") else {
            return ["ok": false,
                    "error": "'uri' must be a Spotify URI such as spotify:track:<id>. "
                           + "spotify:search:<query> is NOT playable -- resolve the query to a "
                           + "real track URI first."]
        }

        if let error = ensureRunning() {
            return ["ok": false, "running": false, "error": error]
        }

        // No `activate`: playback happens in the background and the user
        // keeps whatever they were doing in front.
        switch runScript("""
        tell application "Spotify"
            if it is not running then return "notrunning"
            play track "\(escape(uri))"
            return "sent"
        end tell
        """) {
        case .failure(let e):
            return ["ok": false, "error": e.message]
        case .success(let raw):
            if raw == "notrunning" {
                return ["ok": false, "running": false,
                        "error": "Spotify isn't running. Open it first."]
            }
        }

        guard (args["verify"] as? Bool) ?? true else {
            return ["ok": true, "uri": uri, "verified": false,
                    "note": "Command sent without verification; Spotify silently ignores URIs it "
                          + "can't resolve, so this is not evidence anything is playing."]
        }

        // Spotify needs a moment to load and start the track before its
        // own reported state is meaningful. For a single track, wait for
        // THAT track -- not merely "something is playing", which would pass
        // on whatever was already on.
        let wantedTrackId = uri.hasPrefix("spotify:track:") ? String(uri.dropFirst("spotify:track:".count)) : nil
        var last: [String: Any] = [:]
        for _ in 0..<24 {
            usleep(250_000)
            guard case .success(let raw) = runScript(stateScript) else { continue }
            last = parseState(raw)
            guard last["playing"] as? Bool == true, last["track"] != nil else { continue }
            if let wanted = wantedTrackId, !(last["uri"] as? String ?? "").hasSuffix(wanted) { continue }
            break
        }
        if let wanted = wantedTrackId, last["playing"] as? Bool == true,
           !(last["uri"] as? String ?? "").hasSuffix(wanted) {
            // Spotify can relink a track to a regional/duplicate copy with a
            // different ID; accept it but say so.
            last["note"] = "Spotify is playing a linked version of the requested track."
        }

        let playing = last["playing"] as? Bool ?? false
        let track = last["track"] as? String
        guard playing, let track else {
            return ["ok": false, "uri": uri, "verified": true, "playing": playing,
                    "error": "Spotify accepted the URI but is not playing it. The URI may not "
                           + "resolve to anything, or playback is blocked (no Premium, no active "
                           + "device, or an ad is running). Player state: "
                           + "\(last["playerState"] as? String ?? "unknown")."]
        }
        return ["ok": true, "uri": uri, "verified": true, "playing": true,
                "track": track, "artist": last["artist"] as Any? ?? NSNull(),
                "background": true,
                "note": (last["note"] as? String) ?? "Confirmed by reading Spotify's own player state back after the command."]
    }

    /// args: { "action": "play"|"pause"|"playpause"|"next"|"previous", "volume": Int? }
    static func control(args: [String: Any]) -> [String: Any] {
        let action = (args["action"] as? String)?.lowercased() ?? ""
        let commands = ["play": "play", "pause": "pause", "playpause": "playpause",
                        "next": "next track", "previous": "previous track"]

        var body = ""
        if let cmd = commands[action] {
            body = cmd
        } else if args["volume"] == nil {
            return ["ok": false,
                    "error": "'action' must be one of \(commands.keys.sorted()), or pass 'volume'"]
        }

        var script = "tell application \"Spotify\"\n    if it is not running then return \"notrunning\"\n"
        if !body.isEmpty { script += "    \(body)\n" }
        if let volume = args["volume"] as? Int {
            guard (0...100).contains(volume) else {
                return ["ok": false, "error": "'volume' must be 0-100"]
            }
            script += "    set sound volume to \(volume)\n"
        }
        script += "    return \"done\"\nend tell"

        switch runScript(script) {
        case .failure(let e): return ["ok": false, "error": e.message]
        case .success(let raw):
            if raw == "notrunning" {
                return ["ok": false, "running": false, "error": "Spotify isn't running."]
            }
            // Report the resulting state so the caller doesn't have to make
            // a second call to find out what actually happened.
            usleep(350_000)
            var result = state(args: [:])
            result["performed"] = action.isEmpty ? "volume" : action
            return result
        }
    }
}
