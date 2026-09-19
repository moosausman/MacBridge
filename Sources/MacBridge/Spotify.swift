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
// Two consequences shape this file:
//   1. Resolving a name to a URI happens OUTSIDE it (see tools.py's
//      Spotify Web API lookup). This module only ever takes a real URI.
//   2. Every play here VERIFIES by reading the player state and current
//      track back afterwards, because the command's own result is not
//      evidence that anything happened.
import Foundation

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

    /// args: { "uri": String, "verify": Bool? (default true) }
    ///
    /// Plays a real Spotify URI. Verification is on by default and is the
    /// whole point: `play track` reports success for URIs it silently
    /// discards, so without reading the state back there is no way to tell
    /// a play from a no-op.
    static func playURI(args: [String: Any]) -> [String: Any] {
        guard let uri = args["uri"] as? String, !uri.isEmpty else {
            return ["ok": false, "error": "'uri' is required"]
        }
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

        switch runScript("""
        tell application "Spotify"
            if it is not running then return "notrunning"
            activate
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
        // own reported state is meaningful.
        var last: [String: Any] = [:]
        for _ in 0..<12 {
            usleep(250_000)
            guard case .success(let raw) = runScript(stateScript) else { continue }
            last = parseState(raw)
            if last["playing"] as? Bool == true, last["track"] != nil { break }
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
                "note": "Confirmed by reading Spotify's own player state back after the command."]
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
