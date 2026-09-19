// MacBridge/Sources/MacBridge/AppleScriptRunner.swift
// One place that knows how to run an NSAppleScript safely.
//
// WHY THIS EXISTS
// ---------------
// Shell.swift worked this out first and wrote it down: an NSAppleScript
// must be executed on the MAIN thread, and must have a wall-clock timeout.
// Mail.swift, Safari.swift and System.swift each kept their own
// `runScript(_:)` that did neither, and that combination was a real hang:
//
//   * Apple Event delivery to another GUI app rides the calling process's
//     main run loop to carry the event and get a reply. Every request in
//     this server runs on a DispatchQueue.global() worker (Server.swift's
//     acceptLoop), so calling executeAndReturnError there runs it on a
//     plain worker thread with no run loop integration -- which hangs
//     unpredictably regardless of whether the target app is misbehaving.
//
//   * With no timeout, such a hang is permanent. The only bound was the
//     HTTP client's own timeout, and that just stops the client listening;
//     the server thread stays stuck forever.
//
//   * Worst of all, it isn't contained. Server.swift serialises every
//     UI-affecting route behind `uiLock` -- /safari/, /ui/, /mouse/,
//     /keyboard/, /whatsapp/, /clipboard/, /applescript/ and
//     /shell/stage. A single wedged `tell application "Safari"` holds
//     that lock, so EVERY one of those routes blocks indefinitely behind
//     it. Observed in practice: one `safari_tabs` call hung, and
//     `ui_apps` then timed out at 60s despite the main thread being
//     completely idle.
//
// A timeout cannot cancel an Apple Event -- there is no such API. What it
// does is stop waiting, free the lock, and return a description of what
// happened, so one unresponsive app degrades to one failing route instead
// of taking the whole bridge down.
import Foundation

enum AppleScriptRunner {

    /// Default ceiling. Generous enough for a cold app launch, short
    /// enough that a wedged target doesn't hold `uiLock` for long.
    static let defaultTimeout: TimeInterval = 20

    /// Runs `source` on the main thread with a hard wall-clock timeout.
    ///
    /// Returns the descriptor on success, or an error string. Safe to call
    /// from any background thread; calling it ON the main thread would
    /// deadlock on the semaphore below, which is why it asserts instead.
    static func run(
        _ source: String,
        timeout: TimeInterval = defaultTimeout,
        appName: String = "The target application"
    ) -> (result: NSAppleEventDescriptor?, error: String?) {

        guard !Thread.isMainThread else {
            // Every caller is a request handler on a background queue. If
            // that ever changes, fail loudly rather than deadlocking.
            return (nil, "Internal error: AppleScript must not be dispatched from the main thread")
        }

        guard let script = NSAppleScript(source: source) else {
            return (nil, "Failed to parse internal script")
        }

        var errorInfo: NSDictionary?
        var scriptResult: NSAppleEventDescriptor?
        let done = DispatchSemaphore(value: 0)

        DispatchQueue.main.async {
            scriptResult = script.executeAndReturnError(&errorInfo)
            done.signal()
        }

        guard done.wait(timeout: .now() + timeout) == .success else {
            return (nil, "\(appName) did not respond within \(Int(timeout))s. It may be busy, "
                       + "mid-launch, or waiting on an Automation permission prompt -- check "
                       + "System Settings > Privacy & Security > Automation. The request was "
                       + "abandoned; it may still complete on the app's side.")
        }

        if let errorInfo {
            return (nil, errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error")
        }
        return (scriptResult, nil)
    }

    /// The `Result<String?, ScriptError>` shape Mail/Safari/System's local
    /// `runScript(_:)` helpers already return, so their call sites are
    /// unchanged.
    static func runForString(
        _ source: String,
        timeout: TimeInterval = defaultTimeout,
        appName: String
    ) -> Result<String?, ScriptError> {
        let (result, error) = run(source, timeout: timeout, appName: appName)
        if let error { return .failure(ScriptError(error)) }
        return .success(result?.stringValue)
    }
}
