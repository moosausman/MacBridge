// MacBridge/Sources/MacBridge/Modules/Shortcuts.swift
// Owns: invoking the macOS `shortcuts` command-line tool via Process.
// There is no public Shortcuts framework API — `shortcuts run` (built into
// macOS at /usr/bin/shortcuts since macOS 12) is Apple's own sanctioned
// integration point.
//
// ⚠️ No guardrail here by design — any shortcut on this Mac can be triggered
// by anyone who can reach this HTTP server. Acceptable only because the
// server binds to localhost. Do not expose this port beyond localhost.

import Foundation

enum ShortcutsModule {

    /// args: { "name": String, "input": String? }
    /// "input" is passed via stdin to the shortcut, matching how
    /// `shortcuts run "Name" <<< "input"` behaves.
    static func run(args: [String: Any]) -> [String: Any] {
        guard let name = args["name"] as? String, !name.isEmpty else {
            return ["ok": false, "error": "'name' is required"]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let input = args["input"] as? String {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            stdinPipe.fileHandleForWriting.write(Data(input.utf8))
            stdinPipe.fileHandleForWriting.closeFile()
        }

        do {
            try process.run()
        } catch {
            return ["ok": false, "error": "Failed to launch shortcuts CLI: \(error.localizedDescription)"]
        }

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            return [
                "ok": false,
                "error": stderr.isEmpty ? "Shortcut exited with status \(process.terminationStatus)" : stderr
            ]
        }

        return ["ok": true, "output": stdout]
    }
}