// MacBridge/Sources/MacBridge/Modules/System.swift
// Owns: basic system info and system-level actions (volume, sleep, battery).
// Uses targeted AppleScript / shell-outs for things with no clean Swift API,
// same pattern as Music.swift — kept self-contained rather than routed
// through AppleScript.swift.

import Foundation

enum System {

    /// Delegates to AppleScriptRunner: main-thread execution with a
    /// wall-clock timeout. This used to call
    /// `NSAppleScript.executeAndReturnError` directly on the request's
    /// background thread with no timeout, which could hang forever and --
    /// because Server.swift serialises UI routes behind `uiLock` -- take
    /// every other UI route down with it. See AppleScriptRunner.
    private static func runScript(_ source: String) -> Result<String?, ScriptError> {
        AppleScriptRunner.runForString(source, appName: "System Events")
    }

    /// args: { "level": Int }  — 0 to 100
    static func setVolume(args: [String: Any]) -> [String: Any] {
        guard let level = args["level"] as? Int, (0...100).contains(level) else {
            return ["ok": false, "error": "'level' is required and must be 0-100"]
        }

        switch runScript("set volume output volume \(level)") {
        case .success: return ["ok": true, "level": level]
        case .failure(let scriptError): return ["ok": false, "error": scriptError.message]
        }
    }

    /// args: none
    static func getVolume(args: [String: Any]) -> [String: Any] {
        switch runScript("output volume of (get volume settings)") {
        case .success(let value):
            guard let value, let level = Int(value) else {
                return ["ok": false, "error": "Unexpected response reading volume"]
            }
            return ["ok": true, "level": level]
        case .failure(let scriptError):
            return ["ok": false, "error": scriptError.message]
        }
    }

    /// args: none — battery percentage and charging state, parsed from pmset.
    static func battery(args: [String: Any]) -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "batt"]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
        } catch {
            return ["ok": false, "error": "Failed to run pmset: \(error.localizedDescription)"]
        }

        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        guard let percentRange = output.range(of: #"\d+%"#, options: .regularExpression) else {
            return ["ok": false, "error": "Could not parse battery info — this Mac may not have a battery"]
        }

        let percentString = output[percentRange].dropLast() // drop "%"
        let percent = Int(percentString) ?? -1
        let charging = output.contains("AC Power")

        return ["ok": true, "percent": percent, "charging": charging]
    }

    /// args: none
    static func sleep(args: [String: Any]) -> [String: Any] {
        switch runScript("tell application \"System Events\" to sleep") {
        case .success: return ["ok": true]
        case .failure(let scriptError): return ["ok": false, "error": scriptError.message]
        }
    }

    /// args: none
    static func lock(args: [String: Any]) -> [String: Any] {
        switch runScript("tell application \"System Events\" to keystroke \"q\" using {control down, command down}") {
        case .success: return ["ok": true]
        case .failure(let scriptError): return ["ok": false, "error": scriptError.message]
        }
    }
}