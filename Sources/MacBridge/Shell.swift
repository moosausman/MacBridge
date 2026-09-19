// MacBridge/Sources/MacBridge/Modules/Shell.swift
// Owns: Process (silent shell execution) + Terminal.app/System Events
// (visible, review-before-run staging). Exposes static functions returning
// JSON-safe [String: Any] dictionaries. Knows nothing about HTTP —
// Router.swift is the only caller.
//
// Three execution modes:
//   • stage / stageScript  → opens a NEW Terminal window, pastes the command
//     in, and stops. Nothing runs until a human presses Return in that
//     window. Pass "autoRun": true to also press Return for you — the
//     command runs for real, no human step, but still visibly in a real
//     Terminal window (readFrontWindow can read the result back). Reach for
//     this specifically when you want a human, or a visible Terminal
//     transcript, in the loop — not as the default.
//   • run / runScript      → executes immediately via Process and returns
//     stdout/stderr/exit code directly — no Terminal window, no
//     clipboard/keystroke automation to race or get swallowed. Takes
//     optional "env" (extra/overriding environment variables) and "stdin"
//     (piped to the process). "timeout" <= 0 waits indefinitely instead of
//     killing the process. This is the default, unrestricted path — same
//     trust posture as AppleScript.swift: full user privileges, no
//     sandboxing, no allowlist.
//   • spawn / status / kill / jobs → like run, but detached: returns a
//     jobId immediately instead of blocking the HTTP request, for anything
//     that outlives a single round trip — dev servers, watchers, long
//     builds, downloads.
//
// ⚠️ Whichever mode you use, remember this server binds to localhost only
// by design. Do not expose this port beyond localhost, and don't add auth
// here — add it at the server.
//
// One-time setup for staging: the first call to stage/stageScript triggers
// two macOS permission prompts — "MacBridge would like to control Terminal"
// (Automation) and an Accessibility prompt for the paste/keystroke done via
// System Events. Grant both in System Settings → Privacy & Security →
// Automation / Accessibility, then retry.
//
// ⚠️ If pasting or autoRun silently does nothing (no error, nothing typed),
// check whether Secure Keyboard Entry is on anywhere — most commonly
// Terminal's own Terminal menu → Secure Keyboard Entry. While it's on,
// macOS drops synthetic keystrokes system-wide. stageInTerminal checks for
// this via Keyboard.secureInputWarning(), waits for Terminal to actually be
// frontmost before pasting (rather than guessing with a fixed delay), and
// reads the window back afterward to confirm the paste landed — so a
// swallowed paste comes back as a loud "ok": false instead of a false
// "ok": true that leaves you pressing Return on an empty prompt.

import Foundation
import AppKit

enum Shell {

    /// Absolute ceiling on how long a *blocking* run (run / runScript) may
    /// occupy one of Server.swift's 16 client slots. See execute() for why
    /// an unbounded wait was a whole-server availability problem rather
    /// than just a slow call.
    private static let maxExecuteTimeout: Double = 1800  // 30 minutes

    // ── Staged execution — opens Terminal, writes, waits for a human ──────

    /// args: { "command": String, "cwd": String?, "autoRun": Bool? }
    /// Opens a new Terminal window and pastes `command` in. By default it
    /// stops there, unexecuted, for a human to review and press Return.
    /// Pass "autoRun": true to also press Return automatically — the
    /// command runs for real, with no human step, but still visibly in a
    /// real Terminal window.
    /// Rejects multi-line input: a literal newline in a pasted string acts
    /// as a Return keypress, which would run earlier lines before you get a
    /// chance to review the rest — defeating the point of staging. Chain
    /// multiple steps with `&&`/`;` on one line instead, or use a script
    /// file with `stageScript`.
    static func stage(args: [String: Any]) -> [String: Any] {
        guard let command = args["command"] as? String, !command.isEmpty else {
            return ["ok": false, "error": "'command' is required"]
        }
        guard !command.contains("\n"), !command.contains("\r") else {
            return [
                "ok": false,
                "error": "Multi-line commands aren't allowed for staged review — a pasted " +
                         "newline runs that line immediately, before you see the rest. Join " +
                         "steps with && or ; on one line, or use stageScript for a script file."
            ]
        }

        guard let visible = prependCd(command, cwd: args["cwd"] as? String) else {
            return ["ok": false, "error": "cwd does not exist: \((args["cwd"] as? String) ?? "")"]
        }

        let autoRun = (args["autoRun"] as? Bool) ?? false
        return stageInTerminal(visibleCommand: visible, autoRun: autoRun)
    }

    /// args: { "path": String, "args": [String]?, "cwd": String?, "autoRun": Bool? }
    /// Same idea as `stage`, but for an executable script file — builds the
    /// invocation from `path` + `args` (each shell-quoted) so no shell
    /// string parsing/escaping is needed on the caller's side. Same
    /// "autoRun" opt-in as `stage` applies here too.
    static func stageScript(args: [String: Any]) -> [String: Any] {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return ["ok": false, "error": "'path' is required"]
        }
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            return ["ok": false, "error": "No file exists at \(path)"]
        }
        guard FileManager.default.isExecutableFile(atPath: expanded) else {
            return ["ok": false, "error": "\(path) is not executable — chmod +x it first"]
        }

        let scriptArgs = (args["args"] as? [String]) ?? []
        let invocation = ([expanded] + scriptArgs).map(shellQuote).joined(separator: " ")

        guard let visible = prependCd(invocation, cwd: args["cwd"] as? String) else {
            return ["ok": false, "error": "cwd does not exist: \((args["cwd"] as? String) ?? "")"]
        }

        let autoRun = (args["autoRun"] as? Bool) ?? false
        return stageInTerminal(visibleCommand: visible, autoRun: autoRun)
    }

    /// Runs an NSAppleScript with a hard wall-clock timeout, mirroring the
    /// watchdog execute() already applies to Process. Every raw
    /// NSAppleScript(...).executeAndReturnError(...) call in this file used
    /// to block indefinitely -- the *only* thing bounding it was the
    /// caller's HTTP client timeout, which just gives up listening without
    /// telling this process to stop. This gives Shell.swift itself an
    /// opinion about how long is too long, and a specific reason when it
    /// gives up, instead of always looking like a hang.
    ///
    /// The execution itself is dispatched onto the MAIN thread specifically
    /// -- not just "a background queue" -- because that's where it belongs:
    /// NSAppleScript / Apple Event delivery to another GUI app rides the
    /// calling process's main run loop to actually carry the event and get
    /// a reply, and every request in this server runs off DispatchQueue.
    /// global from Server.swift's acceptLoop, so without this hop, this
    /// call would execute on a plain background worker thread with no run
    /// loop integration at all -- which is exactly the kind of thing that
    /// hangs unpredictably regardless of whether Terminal itself is doing
    /// anything wrong. (An earlier version of this function dispatched to
    /// *another* background queue instead, which doesn't fix this -- it
    /// just moves which background thread the call sits on.)
    ///
    /// Safe against deadlock as long as this is only ever called from a
    /// background thread, which is true for every current caller (nothing
    /// in this codebase runs request handling on the main thread) -- if
    /// that ever changes, calling this from the main thread would deadlock
    /// on DispatchQueue.main.async's implicit wait via the semaphore below.
    ///
    /// Honest limitation: AppleScript/Apple Events have no real cancel. If
    /// the timeout fires, we stop *waiting* and return an error -- the
    /// underlying call may still be running against Terminal underneath us.
    private static func runAppleScript(
        _ source: String,
        timeout: TimeInterval = 10
    ) -> (result: NSAppleEventDescriptor?, error: String?) {
        guard let script = NSAppleScript(source: source) else {
            return (nil, "Failed to build AppleScript")
        }

        var errorInfo: NSDictionary?
        var scriptResult: NSAppleEventDescriptor?
        let done = DispatchSemaphore(value: 0)

        DispatchQueue.main.async {
            scriptResult = script.executeAndReturnError(&errorInfo)
            done.signal()
        }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            return (nil, "Terminal did not respond within \(timeout)s -- it may be too busy " +
                         "(e.g. rendering continuous output) to service Apple Events right now.")
        }
        if let errorInfo {
            return (nil, errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error")
        }
        return (scriptResult, nil)
    }

    /// Reads back the front Terminal window's visible contents — shared by
    /// readFrontWindow and stageInTerminal's paste-confirmation check.
    /// Returns a specific error string (timeout, AppleScript failure, etc.)
    /// alongside nil contents, rather than collapsing every failure mode
    /// into a bare nil the way this used to.
    private static func frontWindowContents() -> (contents: String?, error: String?) {
        let script = """
        tell application "Terminal"
            if (count of windows) is 0 then return ""
            return contents of selected tab of front window
        end tell
        """
        let (result, error) = runAppleScript(script, timeout: 8)
        return (result?.stringValue, error)
    }

    /// args: {}
    /// Reads back the currently visible text buffer of the front Terminal
    /// window's selected tab — lets the agent see what happened after a
    /// human runs a staged command, without ever capturing stdout directly.
    static func readFrontWindow(args: [String: Any]) -> [String: Any] {
        let (contents, error) = frontWindowContents()
        guard let contents else {
            return ["ok": false, "error": error ?? "Failed to read Terminal window"]
        }
        return ["ok": true, "contents": contents]
    }

    // ── Direct execution — silent, immediate, returns output ──────────────
    // The default, unrestricted path: no human review, no Terminal window,
    // just a result. Reach for stage/stageScript only when you specifically
    // want eyes on it first.

    /// args: { "command": String, "cwd": String?, "timeout": Double?,
    ///         "env": [String:String]?, "stdin": String? }
    /// "timeout" <= 0 waits indefinitely instead of killing the process.
    static func run(args: [String: Any]) -> [String: Any] {
        guard let command = args["command"] as? String, !command.isEmpty else {
            return ["ok": false, "error": "'command' is required"]
        }
        let timeout = (args["timeout"] as? Double) ?? 60.0
        let cwd = (args["cwd"] as? String).map { ($0 as NSString).expandingTildeInPath }
            ?? FileManager.default.homeDirectoryForCurrentUser.path

        return execute(
            executable: "/bin/zsh",
            arguments: ["-c", command],
            cwd: cwd,
            timeout: timeout,
            env: args["env"] as? [String: String],
            stdin: args["stdin"] as? String
        )
    }

    /// args: { "path": String, "args": [String]?, "cwd": String?, "timeout": Double?,
    ///         "env": [String:String]?, "stdin": String? }
    static func runScript(args: [String: Any]) -> [String: Any] {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return ["ok": false, "error": "'path' is required"]
        }
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            return ["ok": false, "error": "No file exists at \(path)"]
        }
        guard FileManager.default.isExecutableFile(atPath: expanded) else {
            return ["ok": false, "error": "\(path) is not executable — chmod +x it first"]
        }

        let scriptArgs = (args["args"] as? [String]) ?? []
        let timeout = (args["timeout"] as? Double) ?? 60.0
        let cwd = (args["cwd"] as? String).map { ($0 as NSString).expandingTildeInPath }
            ?? FileManager.default.homeDirectoryForCurrentUser.path

        return execute(
            executable: expanded,
            arguments: scriptArgs,
            cwd: cwd,
            timeout: timeout,
            env: args["env"] as? [String: String],
            stdin: args["stdin"] as? String
        )
    }

    // ── Background execution — detached, returns a jobId immediately ──────
    // For anything that outlives one HTTP call: dev servers, watchers, long
    // builds, downloads. Unlike run/runScript, the request returns right
    // away; poll status, stop with kill. Jobs live only in memory — they
    // don't survive a MacBridge restart.

    /// Cap on captured output per stream, per job. A spawned dev server or
    /// watcher can log steadily for hours; without a bound, `stdout` here
    /// grew forever in memory with nothing ever trimming or rotating it.
    /// Keeping the TAIL rather than the head is deliberate -- for a
    /// long-running process the recent lines are the interesting ones.
    private static let maxJobOutputBytes = 256 * 1024

    /// How long a finished job stays queryable before it's swept. Jobs were
    /// previously never removed from `jobs` at all: every spawn leaked its
    /// Job, its Process, and its accumulated output for the lifetime of the
    /// server. Ten minutes is long enough to collect a result at leisure.
    private static let finishedJobRetention: TimeInterval = 600

    private final class Job {
        let process: Process
        private(set) var stdout = Data()
        private(set) var stderr = Data()
        private(set) var stdoutTruncated = false
        private(set) var stderrTruncated = false
        let lock = NSLock()
        let command: String
        var finishedAt: Date?

        init(process: Process, command: String) {
            self.process = process
            self.command = command
        }

        /// Appends, then trims from the front so the buffer holds at most
        /// `maxJobOutputBytes` -- a sliding window over the most recent
        /// output rather than an unbounded transcript.
        func append(_ chunk: Data, toStdout: Bool) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            if toStdout {
                stdout.append(chunk)
                if stdout.count > Shell.maxJobOutputBytes {
                    stdout.removeFirst(stdout.count - Shell.maxJobOutputBytes)
                    stdoutTruncated = true
                }
            } else {
                stderr.append(chunk)
                if stderr.count > Shell.maxJobOutputBytes {
                    stderr.removeFirst(stderr.count - Shell.maxJobOutputBytes)
                    stderrTruncated = true
                }
            }
        }

        func snapshot() -> (out: String, err: String, outTrunc: Bool, errTrunc: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (String(data: stdout, encoding: .utf8) ?? "",
                    String(data: stderr, encoding: .utf8) ?? "",
                    stdoutTruncated, stderrTruncated)
        }
    }

    private static var jobs: [String: Job] = [:]
    private static let jobsLock = NSLock()

    /// Drops finished jobs whose retention window has passed. Called from
    /// spawn/jobList, so housekeeping rides along with normal traffic and
    /// needs no timer of its own. Caller must NOT already hold jobsLock.
    private static func sweepFinishedJobs() {
        let now = Date()
        jobsLock.lock()
        defer { jobsLock.unlock() }
        for (id, job) in jobs {
            if job.finishedAt == nil, !job.process.isRunning {
                job.finishedAt = now          // first sighting of the exit
            }
            if let finished = job.finishedAt,
               now.timeIntervalSince(finished) > finishedJobRetention {
                jobs.removeValue(forKey: id)
            }
        }
    }

    /// args: { "command": String, "cwd": String?, "env": [String:String]? }
    /// Starts `command` detached via /bin/zsh -c and returns a jobId right
    /// away. Nothing here waits for it to finish.
    static func spawn(args: [String: Any]) -> [String: Any] {
        guard let command = args["command"] as? String, !command.isEmpty else {
            return ["ok": false, "error": "'command' is required"]
        }
        let cwd = (args["cwd"] as? String).map { ($0 as NSString).expandingTildeInPath }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard FileManager.default.fileExists(atPath: cwd) else {
            return ["ok": false, "error": "cwd does not exist: \(cwd)"]
        }

        sweepFinishedJobs()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = mergedEnvironment(args["env"] as? [String: String])

        // Detach stdin. A spawned job has no console; leaving it inheriting
        // MacBridge's stdin lets an interactive command block forever
        // waiting for input nobody can supply.
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let job = Job(process: process, command: command)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            job.append(handle.availableData, toStdout: true)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            job.append(handle.availableData, toStdout: false)
        }

        // Tear the readers down when the process exits. Leaving a
        // readabilityHandler installed on a closed pipe keeps a dispatch
        // source (and the FileHandle) alive indefinitely -- another slow
        // leak, one per spawned job.
        process.terminationHandler = { [weak job] _ in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            jobsLock.lock()
            job?.finishedAt = Date()
            jobsLock.unlock()
        }

        do {
            try process.run()
        } catch {
            return ["ok": false, "error": "Failed to launch: \(error.localizedDescription)"]
        }

        let jobId = UUID().uuidString
        jobsLock.lock(); jobs[jobId] = job; jobsLock.unlock()

        return [
            "ok": true,
            "jobId": jobId,
            "pid": Int(process.processIdentifier),
            "command": command,
            "cwd": cwd
        ]
    }

    /// args: { "jobId": String }
    /// Output accumulated so far, whether it's still running, and (once it
    /// isn't) the exit code.
    static func jobStatus(args: [String: Any]) -> [String: Any] {
        guard let jobId = args["jobId"] as? String else {
            return ["ok": false, "error": "'jobId' is required"]
        }
        jobsLock.lock()
        let job = jobs[jobId]
        jobsLock.unlock()
        guard let job else {
            return ["ok": false, "error": "Unknown jobId"]
        }

        let captured = job.snapshot()

        let running = job.process.isRunning
        var result: [String: Any] = [
            "ok": true,
            "jobId": jobId,
            "command": job.command,
            "running": running,
            "pid": Int(job.process.processIdentifier),
            "stdout": captured.out,
            "stderr": captured.err
        ]
        // Say so when output was dropped, rather than silently handing back
        // a window and letting the caller believe it's the whole transcript.
        if captured.outTrunc || captured.errTrunc {
            result["truncated"] = true
            result["note"] = "Output exceeded \(maxJobOutputBytes / 1024)KB per stream; " +
                             "showing the most recent portion only. Redirect to a file " +
                             "in the command itself if you need the full log."
        }
        if !running {
            result["exitCode"] = Int(job.process.terminationStatus)
        }
        return result
    }

    /// args: { "jobId": String, "signal": String? }  — "term" (default, graceful) or "kill" (force)
    static func jobKill(args: [String: Any]) -> [String: Any] {
        guard let jobId = args["jobId"] as? String else {
            return ["ok": false, "error": "'jobId' is required"]
        }
        jobsLock.lock()
        let job = jobs[jobId]
        jobsLock.unlock()
        guard let job else {
            return ["ok": false, "error": "Unknown jobId"]
        }

        let sig = (args["signal"] as? String)?.lowercased() ?? "term"
        guard ["term", "kill"].contains(sig) else {
            return ["ok": false, "error": "signal must be \"term\" or \"kill\""]
        }
        guard job.process.isRunning else {
            return ["ok": true, "jobId": jobId, "signaled": sig,
                    "note": "Job had already exited; nothing to signal",
                    "exitCode": Int(job.process.terminationStatus)]
        }

        let pid = job.process.processIdentifier
        let signalNumber = (sig == "kill") ? SIGKILL : SIGTERM

        // Signal the process GROUP first (negative pid), then the process
        // itself as a fallback.
        //
        // The command runs as `/bin/zsh -c "<command>"`, and zsh commonly
        // exec's straight into a single command or forks children for a
        // pipeline. Signalling only the zsh pid -- which is what
        // Process.terminate() and the old kill(pid, SIGKILL) both did --
        // reaped the wrapper and left whatever it had started still running,
        // reparented to launchd: invisible to shell_jobs, and unkillable
        // through this API. "Kill the dev server" appeared to work and
        // didn't, and the port stayed bound.
        //
        // killpg only reaches a separate group if the child actually made
        // one; when it hasn't, ESRCH comes back and the direct kill below
        // does the job. Both are attempted, and success of either counts.
        let groupResult = killpg(pid, signalNumber)
        let directResult = kill(pid, signalNumber)

        guard groupResult == 0 || directResult == 0 else {
            return ["ok": false, "jobId": jobId,
                    "error": "Could not signal pid \(pid) (errno \(errno))"]
        }

        return ["ok": true, "jobId": jobId, "signaled": sig, "pid": Int(pid),
                "signaledProcessGroup": groupResult == 0,
                "note": "Signal delivered. A process can ignore SIGTERM -- " +
                        "poll shell_job_status to confirm it actually exited, " +
                        "and use signal=\"kill\" if it didn't."]
    }

    /// args: {}
    /// Lists every job spawned this run, with pid and running state.
    static func jobList(args: [String: Any]) -> [String: Any] {
        sweepFinishedJobs()
        jobsLock.lock()
        let list: [[String: Any]] = jobs.map { id, job in
            [
                "jobId": id,
                "pid": Int(job.process.processIdentifier),
                "command": job.command,
                "running": job.process.isRunning
            ]
        }
        jobsLock.unlock()
        return ["ok": true, "jobs": list,
                "note": "Finished jobs stay listed for \(Int(finishedJobRetention / 60)) " +
                        "minutes so their output can still be collected, then are dropped."]
    }

    // ── Shared helpers ──────────────────────────────────────────────────

    /// Starts from the process's own environment and layers `overrides` on
    /// top — callers only need to specify what they want to add or change.
    private static func mergedEnvironment(_ overrides: [String: String]?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        guard let overrides else { return env }
        for (key, value) in overrides { env[key] = value }
        return env
    }

    /// Prepends `cd <cwd> &&` so navigation is part of the one line the
    /// human reviews, rather than something that happens silently before
    /// they see anything. Returns nil if `cwd` was given but doesn't exist.
    private static func prependCd(_ command: String, cwd: String?) -> String? {
        guard let cwd else { return command }
        let expanded = (cwd as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { return nil }
        return "cd \(shellQuote(expanded)) && \(command)"
    }

    /// Single-quotes a string for safe use inside a *shell* command line.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes a string for safe use inside an *AppleScript* string literal.
    private static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Strips whitespace so line-wrap-induced breaks in Terminal's window
    /// buffer don't cause a false mismatch when confirming a paste landed.
    private static func normalizedForMatch(_ s: String) -> String {
        s.filter { !$0.isWhitespace }
    }

    /// Opens a new Terminal window and pastes `visibleCommand` into it via
    /// the clipboard (reliable for quotes/backticks/unicode — far more so
    /// than simulating individual keystrokes). The user's existing
    /// clipboard contents are saved and restored afterward. If `autoRun` is
    /// true, also presses Return afterward so the command actually
    /// executes; otherwise it's left sitting there, unexecuted, for a human
    /// to review and run.
    ///
    /// Split into three AppleScript calls with a Swift-side wait in
    /// between (rather than one script with a fixed `delay`), and a
    /// paste-confirmation read at the end. `do script` opening a window
    /// doesn't guarantee the window manager has handed it focus yet, and a
    /// flat `delay 0.4` either wastes time or loses that race depending on
    /// system load — the likely cause of "I pressed Return and nothing
    /// happened": the paste silently landed nowhere because Terminal
    /// wasn't actually frontmost yet when "cmd+v" was sent, so Return just
    /// submitted an empty line.
    private static func stageInTerminal(visibleCommand: String, autoRun: Bool) -> [String: Any] {
        if let warning = Keyboard.secureInputWarning() {
            return ["ok": false, "error": warning]
        }

        let escapedCommand = escapeForAppleScript(visibleCommand)

        // Step 1 — save the current clipboard, load the command onto it,
        // and open a fresh Terminal window.
        let openScript = """
        try
            set savedClipboard to (the clipboard as text)
        on error
            set savedClipboard to ""
        end try
        set the clipboard to "\(escapedCommand)"
        tell application "Terminal"
            activate
            do script ""
        end tell
        return savedClipboard
        """
        let (openResult, openError) = runAppleScript(openScript, timeout: 10)
        if let openError {
            return [
                "ok": false,
                "error": "Failed to open a Terminal window: \(openError). If this is the first " +
                         "run, grant MacBridge Automation access to Terminal in System " +
                         "Settings → Privacy & Security → Automation, then retry."
            ]
        }
        let savedClipboard = openResult?.stringValue ?? ""

        // Step 2 — wait until Terminal is confirmed frontmost before typing
        // into it, instead of guessing with a fixed delay.
        guard waitForFrontmost(appName: "Terminal", timeout: 5.0) else {
            restoreClipboard(savedClipboard)
            return [
                "ok": false,
                "error": "Terminal never came to the foreground — grant MacBridge Automation " +
                         "access to Terminal in System Settings → Privacy & Security, then retry."
            ]
        }

        // Step 3 — paste, optionally press Return, then restore the
        // clipboard.
        let runStep = autoRun
            ? "\n\ndelay 0.15\ntell application \"System Events\" to key code 36"
            : ""
        let pasteScript = """
        tell application "System Events"
            tell process "Terminal"
                set frontmost to true
                keystroke "v" using command down
            end tell
        end tell
        \(runStep)
        delay 0.2
        set the clipboard to "\(escapeForAppleScript(savedClipboard))"
        """
        let (_, pasteError) = runAppleScript(pasteScript, timeout: 10)
        if let pasteError {
            return [
                "ok": false,
                "error": "Failed to paste into Terminal: \(pasteError). If this is the first run, " +
                         "grant MacBridge Accessibility access in System Settings → Privacy & " +
                         "Security → Accessibility, then retry."
            ]
        }

        // Step 4 — confirm the paste actually landed. Secure Keyboard Entry,
        // a not-yet-granted Accessibility grant, or Terminal being too busy
        // to answer right now (e.g. mid continuous-output command) can all
        // leave this unconfirmed; this used to return "ok": true regardless.
        let (windowContents, confirmError) = frontWindowContents()
        let landed = windowContents.map {
            normalizedForMatch($0).contains(normalizedForMatch(visibleCommand))
        } ?? false

        guard landed else {
            if let confirmError {
                return [
                    "ok": false,
                    "error": "Pasted into Terminal, but couldn't confirm it landed: \(confirmError)"
                ]
            }
            return [
                "ok": false,
                "error": "Opened Terminal but the command never appeared in the window, so the " +
                         "paste keystroke was swallowed. Check: Terminal menu → Secure Keyboard " +
                         "Entry is off (in every open terminal app), and MacBridge has both " +
                         "Automation access to Terminal and Accessibility access in System " +
                         "Settings → Privacy & Security."
            ]
        }

        if autoRun {
            print("⚠️ Shell.stage autoRun executed: \(visibleCommand)")
        }

        return [
            "ok": true,
            "staged": !autoRun,
            "executed": autoRun,
            "command": visibleCommand,
            "note": autoRun
                ? "Pasted into a new Terminal window and pressed Return — it's running now. " +
                  "Use readFrontWindow to check on it."
                : "Written to a new Terminal window — nothing has run yet. Review it and press Return to execute."
        ]
    }

    /// Polls NSWorkspace until `appName` is confirmed frontmost instead of a
    /// fixed delay — same pattern Keyboard.bringToFrontAndWait uses for app
    /// activation.
    private static func waitForFrontmost(appName: String, timeout: TimeInterval) -> Bool {
        let lower = appName.lowercased()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (NSWorkspace.shared.frontmostApplication?.localizedName ?? "").lowercased() == lower {
                return true
            }
            usleep(20_000)
        }
        return false
    }

    /// Best-effort clipboard restore for the early-failure path in
    /// stageInTerminal (Terminal never came forward), where the paste
    /// script — which normally restores the clipboard itself — never runs.
    @discardableResult
    private static func restoreClipboard(_ text: String) -> Bool {
        let script = "set the clipboard to \"\(escapeForAppleScript(text))\""
        let (_, error) = runAppleScript(script, timeout: 5)
        return error == nil
    }

    /// Runs `executable` with `arguments`, capturing stdout/stderr on
    /// background readers (avoids the classic Process deadlock where a
    /// child blocks writing to a full pipe while the parent is blocked
    /// waiting for exit), optionally feeding `stdin`, and enforcing
    /// `timeout` via a watchdog that SIGTERMs then SIGKILLs a runaway
    /// process. `timeout <= 0` waits indefinitely instead of applying the
    /// watchdog.
    private static func execute(
        executable: String,
        arguments: [String],
        cwd: String,
        timeout: Double,
        env: [String: String]? = nil,
        stdin: String? = nil
    ) -> [String: Any] {

        guard FileManager.default.fileExists(atPath: cwd) else {
            return ["ok": false, "error": "cwd does not exist: \(cwd)"]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = mergedEnvironment(env)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let stdin {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
            stdinPipe.fileHandleForWriting.closeFile()
        }

        var stdout = Data()
        var stderr = Data()
        let lock = NSLock()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); stdout.append(chunk); lock.unlock()
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); stderr.append(chunk); lock.unlock()
        }

        let doneSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in doneSemaphore.signal() }

        do {
            try process.run()
        } catch {
            return ["ok": false, "error": "Failed to launch \(executable): \(error.localizedDescription)"]
        }

        // A blocking run is ALWAYS bounded now. `timeout <= 0` used to mean
        // a bare doneSemaphore.wait() -- wait forever -- and that was a way
        // to wedge the entire server, not just the one call:
        //
        //   Server.swift admits at most 16 concurrent clients
        //   (`clients = DispatchSemaphore(value: 16)`), and each request
        //   occupies its slot and a global-queue thread for as long as its
        //   handler runs. Sixteen never-terminating shell_run calls -- a
        //   dev server, `tail -f`, anything interactive waiting on input --
        //   and MacBridge stops answering ANY route, /health included, with
        //   no way back short of killing it. The Python wrapper actively
        //   advertised this footgun ("Pass 0 to wait indefinitely") and
        //   matched it with `timeout=None` client-side, so nothing anywhere
        //   in the stack would ever give up.
        //
        // Anything legitimately longer-running belongs in shell_spawn,
        // which returns immediately and is polled -- that's the whole
        // reason it exists.
        let effectiveTimeout = (timeout <= 0) ? maxExecuteTimeout : min(timeout, maxExecuteTimeout)
        let timedOut = doneSemaphore.wait(timeout: .now() + effectiveTimeout) == .timedOut

        if timedOut {
            process.terminate()
            _ = doneSemaphore.wait(timeout: .now() + 2)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        lock.lock()
        let outStr = String(data: stdout, encoding: .utf8) ?? ""
        let errStr = String(data: stderr, encoding: .utf8) ?? ""
        lock.unlock()

        if timedOut {
            let hitCeiling = (timeout <= 0 || timeout > maxExecuteTimeout)
            return [
                "ok": false,
                "error": "Command timed out after \(Int(effectiveTimeout))s and was killed"
                    + (hitCeiling
                       ? " (server ceiling for a blocking run -- use shell_spawn for "
                         + "anything meant to keep running, then poll shell_job_status)"
                       : ""),
                "stdout": outStr,
                "stderr": errStr,
                "cwd": cwd
            ]
        }

        return [
            "ok": process.terminationStatus == 0,
            "exitCode": Int(process.terminationStatus),
            "stdout": outStr,
            "stderr": errStr,
            "cwd": cwd
        ]
    }
}