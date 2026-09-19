// MacBridge/Sources/MacBridge/Modules/Keyboard.swift
// Owns: CGEvent (Quartz Event Services) — synthetic keyboard input.
// Exposes static functions returning JSON-safe [String: Any] dictionaries.
// Knows nothing about HTTP — Router.swift is the only caller.
//
// This drives whatever app currently has keyboard focus — Safari, Terminal,
// a native app, a text field in any web page. Pass `app` to bring a
// specific app forward first; otherwise it types wherever focus already is.
//
// ⚠️ Same trust posture as AppleScript.swift/Shell.swift: no allowlist, no
// review step, full user privileges — whatever's focused receives whatever
// you send it, including into password fields if one happens to have focus.
// Acceptable only because this server binds to localhost. If you want a
// review-before-run pattern for a specific workflow, stage it as a shell
// command instead (see Shell.stage) rather than typing it live.
//
// Requires Accessibility permission (System Settings → Privacy & Security →
// Accessibility) — same bucket Shell.stage's Terminal automation uses, so
// if you already granted that, this is likely already covered. `typeText`
// and `pressKey` check AXIsProcessTrusted() first and fail loudly with a
// clear message instead of silently posting events nobody receives.
//
// `pressKey`'s letter/number keys use standard US ANSI virtual keycodes —
// correct for shortcuts like cmd+l / cmd+t / cmd+c on a US keyboard layout.
// If your Mac uses a different physical layout, those may not map to the
// labeled key. `typeText` is unaffected: it injects Unicode text directly,
// not simulated key positions, so it's layout-independent.
//
// ⚠️ If typing/pressing silently does nothing — no error, no output, no
// visible effect — check whether Secure Keyboard Entry is on anywhere,
// most commonly Terminal's own Terminal menu → Secure Keyboard Entry.
// While it's on, macOS drops every synthetic keystroke system-wide with no
// error. `typeText`/`pressKey` check `secureInputWarning()` first now and
// fail loudly with that explanation instead of silently doing nothing.
// Shell.swift's `stageInTerminal` checks the same thing before pasting.
//
// Activating a target `app` used to sleep a fixed 200ms and hope it had
// finished coming forward before typing started — flaky for anything
// slower to launch. `bringToFrontAndWait` polls `NSWorkspace`'s
// `frontmostApplication` instead and returns as soon as it's confirmed (or
// after a short timeout), so typing doesn't race the app switch.

import AppKit
import CoreGraphics
import ApplicationServices
import Carbon.HIToolbox

enum Keyboard {

    // ── Text & key input ───────────────────────────────────────────────

    /// args: { "text": String, "app": String? }
    /// Types `text` at the current keyboard focus via Unicode injection —
    /// handles any character (accents, emoji, symbols, any layout) without
    /// needing a keycode for each glyph. Sent in small chunks since some
    /// apps mishandle very long single text events.
    static func typeText(args: [String: Any]) -> [String: Any] {
        guard let text = args["text"] as? String, !text.isEmpty else {
            return ["ok": false, "error": "'text' is required"]
        }
        guard AXIsProcessTrusted() else {
            return [
                "ok": false,
                "error": "Not trusted for Accessibility — grant MacBridge access in " +
                         "System Settings → Privacy & Security → Accessibility, then retry."
            ]
        }
        if let warning = secureInputWarning() {
            return ["ok": false, "error": warning]
        }

        if let appName = args["app"] as? String, !appName.isEmpty {
            guard bringToFrontAndWait(appName: appName) else {
                return ["ok": false, "error": "Could not find/activate app '\(appName)'"]
            }
        }

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return ["ok": false, "error": "Failed to create event source"]
        }

        let chunkSize = 20
        let utf16 = Array(text.utf16)
        var index = 0
        while index < utf16.count {
            let end = min(index + chunkSize, utf16.count)
            let chunk = Array(utf16[index..<end])

            guard
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else {
                return ["ok": false, "error": "Failed to build text event"]
            }
            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)

            index = end
            if index < utf16.count { usleep(4_000) }
        }

        return ["ok": true, "typed": text]
    }

    /// args: { "key": String, "modifiers": [String]?, "app": String? }
    /// Presses one named key, optionally with modifiers held — e.g.
    /// {"key": "l", "modifiers": ["cmd"]} for Safari's address bar,
    /// {"key": "return"} to submit, {"key": "tab"} to move fields.
    /// Known keys: a-z, 0-9, punctuation (- = [ ] \ ; ' , . / `),
    /// return/enter, tab, space, delete/backspace, forwarddelete, escape/esc,
    /// left/right/up/down, home, end, pageup, pagedown, capslock, help,
    /// f1-f20, volumeup, volumedown, mute.
    /// Known modifiers: cmd/command, shift, option/alt, control/ctrl, fn.
    static func pressKey(args: [String: Any]) -> [String: Any] {
        guard let keyName = args["key"] as? String, !keyName.isEmpty else {
            return ["ok": false, "error": "'key' is required"]
        }
        guard let keyCode = namedKeyCodes[keyName.lowercased()] else {
            return ["ok": false, "error": "Unknown key '\(keyName)'"]
        }
        guard AXIsProcessTrusted() else {
            return [
                "ok": false,
                "error": "Not trusted for Accessibility — grant MacBridge access in " +
                         "System Settings → Privacy & Security → Accessibility, then retry."
            ]
        }
        if let warning = secureInputWarning() {
            return ["ok": false, "error": warning]
        }

        if let appName = args["app"] as? String, !appName.isEmpty {
            guard bringToFrontAndWait(appName: appName) else {
                return ["ok": false, "error": "Could not find/activate app '\(appName)'"]
            }
        }

        var flags: CGEventFlags = []
        let modifierNames = (args["modifiers"] as? [String]) ?? []
        for m in modifierNames {
            guard let flag = modifierFlags[m.lowercased()] else {
                return ["ok": false, "error": "Unknown modifier '\(m)' — use cmd, shift, option, control, fn"]
            }
            flags.insert(flag)
        }

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return ["ok": false, "error": "Failed to create event source"]
        }
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return ["ok": false, "error": "Failed to build key event"]
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        return ["ok": true, "key": keyName, "modifiers": modifierNames]
    }

    /// args: { "app": String?, "steps": [ {"type":"text","text":String} |
    ///         {"type":"key","key":String,"modifiers":[String]?} |
    ///         {"type":"wait","ms":Int} ] }
    /// Runs several typeText/pressKey/wait steps back-to-back in one call —
    /// e.g. filling a multi-field form — so focus can't drift between steps
    /// the way it might across separate HTTP round-trips. Stops and reports
    /// which step failed if one does; earlier steps have already happened.
    static func runSequence(args: [String: Any]) -> [String: Any] {
        guard let steps = args["steps"] as? [[String: Any]], !steps.isEmpty else {
            return ["ok": false, "error": "'steps' is required and must be a non-empty array"]
        }

        if let appName = args["app"] as? String, !appName.isEmpty {
            guard bringToFrontAndWait(appName: appName) else {
                return ["ok": false, "error": "Could not find/activate app '\(appName)'"]
            }
        }

        for (i, step) in steps.enumerated() {
            guard let type = step["type"] as? String else {
                return ["ok": false, "error": "step \(i) is missing 'type'", "stepsCompleted": i]
            }

            let result: [String: Any]
            switch type {
            case "text":
                result = typeText(args: step)
            case "key":
                result = pressKey(args: step)
            case "wait":
                let ms = (step["ms"] as? Int) ?? 200
                usleep(useconds_t(max(0, ms) * 1000))
                continue
            default:
                return ["ok": false, "error": "step \(i) has unknown type '\(type)'", "stepsCompleted": i]
            }

            if (result["ok"] as? Bool) != true {
                let message = (result["error"] as? String) ?? "unknown error"
                return ["ok": false, "error": "step \(i) (\(type)) failed: \(message)", "stepsCompleted": i]
            }
        }

        return ["ok": true, "stepsCompleted": steps.count]
    }

    // ── App focus ───────────────────────────────────────────────────────

    /// args: { "app": String }
    /// Brings a running app forward, launching it first if it isn't running.
    static func activateApp(args: [String: Any]) -> [String: Any] {
        guard let appName = args["app"] as? String, !appName.isEmpty else {
            return ["ok": false, "error": "'app' is required"]
        }
        guard bringToFront(appName: appName) else {
            return ["ok": false, "error": "Could not find/activate app '\(appName)'"]
        }
        return ["ok": true, "app": appName]
    }

    /// args: {}
    /// Reports which app currently has keyboard focus — check this before
    /// typing if you're not sure what's frontmost.
    static func frontmostApp(args: [String: Any]) -> [String: Any] {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return ["ok": false, "error": "No frontmost application"]
        }
        return [
            "ok": true,
            "name": app.localizedName ?? "",
            "bundleId": app.bundleIdentifier ?? ""
        ]
    }

    /// args: {}
    /// Checks (and, the first time, prompts for) Accessibility permission,
    /// which typeText/pressKey/runSequence require to post synthetic events.
    static func checkAccessibility(args: [String: Any]) -> [String: Any] {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        return ["ok": true, "trusted": trusted]
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    /// Checks whether Secure Keyboard Entry is active anywhere on the
    /// system — most commonly toggled via Terminal's Terminal menu →
    /// Secure Keyboard Entry, but any app holding a focused password field
    /// can enable it system-wide. While it's on, macOS silently discards
    /// every synthetic keystroke this module posts: no error, no exception,
    /// nothing typed. Callers check this before posting events so the
    /// failure comes back as a clear message instead of looking like
    /// nothing happened at all.
    static func secureInputWarning() -> String? {
        guard IsSecureEventInputEnabled() else { return nil }
        return "Secure Keyboard Entry is on, so macOS is silently discarding synthetic " +
               "keystrokes system-wide. Turn it off (commonly Terminal → Secure Keyboard " +
               "Entry — check every open terminal app — or dismiss whatever password field " +
               "has focus) and retry."
    }

    @discardableResult
    private static func bringToFront(appName: String) -> Bool {
        let lower = appName.lowercased()
        if let match = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName ?? "").lowercased() == lower
        }) {
            return match.activate(options: [])
        }
        // Not currently running — launch it through the real `open` CLI, which
        // goes through Launch Services' own name resolution (the same path
        // Spotlight/Finder use). NSWorkspace.launchApplication(_:) is
        // deprecated and resolves app names less reliably — this was a
        // latent gap in "activate any app": it would silently fail to find
        // apps that weren't already running, whenever Launch Services'
        // legacy name lookup didn't match.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appName]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Activates `appName`, then polls `NSWorkspace.frontmostApplication`
    /// until it's confirmed frontmost instead of sleeping a fixed guess —
    /// avoids racing slow-launching apps, which a flat `usleep` either
    /// wastes time on (if the app was already fast) or loses to (if it
    /// wasn't). Gives up after `timeout` and proceeds anyway, matching the
    /// old behavior for apps that never reliably report themselves as
    /// frontmost (some background-agent-style apps).
    @discardableResult
    private static func bringToFrontAndWait(appName: String, timeout: TimeInterval = 3.0) -> Bool {
        guard bringToFront(appName: appName) else { return false }

        let lower = appName.lowercased()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (NSWorkspace.shared.frontmostApplication?.localizedName ?? "").lowercased() == lower {
                return true
            }
            usleep(20_000) // 20ms between checks
        }
        return true
    }

    private static let modifierFlags: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand,
        "shift": .maskShift,
        "option": .maskAlternate, "alt": .maskAlternate,
        "control": .maskControl, "ctrl": .maskControl,
        "fn": .maskSecondaryFn
    ]

    // Standard US ANSI virtual keycodes (HIToolbox's Events.h values,
    // reproduced here directly rather than pulled from Carbon's keycode
    // constants — Carbon.HIToolbox is now imported above, but only for
    // IsSecureEventInputEnabled(), not for these).
    private static let namedKeyCodes: [String: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B,
        "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17,
        "=": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D,
        "]": 0x1E, "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23,
        "return": 0x24, "enter": 0x24,
        "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
        "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F,
        "tab": 0x30, "space": 0x31, "`": 0x32,
        "delete": 0x33, "backspace": 0x33,
        "escape": 0x35, "esc": 0x35,
        "capslock": 0x39,
        "f17": 0x40, "volumeup": 0x48, "volumedown": 0x49, "mute": 0x4A,
        "f18": 0x4F, "f19": 0x50, "f20": 0x5A,
        "f5": 0x60, "f6": 0x61, "f7": 0x62, "f3": 0x63, "f8": 0x64, "f9": 0x65,
        "f11": 0x67, "f13": 0x69, "f16": 0x6A, "f14": 0x6B,
        "f10": 0x6D, "f12": 0x6F, "f15": 0x71,
        "help": 0x72, "home": 0x73, "pageup": 0x74, "forwarddelete": 0x75,
        "f4": 0x76, "end": 0x77, "f2": 0x78, "pagedown": 0x79, "f1": 0x7A,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E
    ]
}