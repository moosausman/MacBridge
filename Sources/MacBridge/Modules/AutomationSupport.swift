import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import CoreFoundation

enum PowerError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

enum PowerSupport {
    static func result(_ body: () throws -> [String: Any]) -> [String: Any] {
        do { return try body() }
        catch { return ["ok": false, "error": error.localizedDescription] }
    }
    static func main<T>(_ body: () -> T) -> T {
        Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
    }
    static func text(_ args: [String: Any], _ key: String, max: Int = 16000) throws -> String {
        guard let value = args[key] as? String, !value.isEmpty, value.count <= max else {
            throw PowerError.message("'\(key)' must be a nonempty string of at most \(max) characters")
        }
        return value
    }
    static func number(_ args: [String: Any], _ key: String, default fallback: Double? = nil,
                       range: ClosedRange<Double>? = nil) throws -> Double {
        let value: Double
        if let raw = args[key] {
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else {
                throw PowerError.message("'\(key)' must be a number")
            }
            value = n.doubleValue
        } else if let fallback { value = fallback }
        else { throw PowerError.message("Missing '\(key)'") }
        guard value.isFinite, range?.contains(value) ?? true else {
            throw PowerError.message("'\(key)' is outside the supported range")
        }
        return value
    }
    static func integer(_ args: [String: Any], _ key: String, default fallback: Int,
                        range: ClosedRange<Int>) throws -> Int {
        let n = try number(args, key, default: Double(fallback), range: Double(range.lowerBound)...Double(range.upperBound))
        guard n.rounded() == n else { throw PowerError.message("'\(key)' must be an integer") }
        return Int(n)
    }
    static func trusted() throws {
        guard AXIsProcessTrusted() else {
            throw PowerError.message("Enable MacBridge in System Settings > Privacy & Security > Accessibility, then restart MacBridge")
        }
    }
    static func displays() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else {
            throw PowerError.message("Could not enumerate displays")
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            throw PowerError.message("Could not enumerate displays")
        }
        return Array(ids.prefix(Int(count)))
    }
    static func point(_ args: [String: Any], x: String = "x", y: String = "y") throws -> CGPoint {
        let p = CGPoint(x: try number(args, x), y: try number(args, y))
        guard try displays().contains(where: { CGDisplayBounds($0).contains(p) }) else {
            throw PowerError.message("Point is outside all active displays. Use /screen/displays for global point bounds")
        }
        return p
    }
    static func rect(_ r: CGRect) -> [String: Any] {
        ["x": r.origin.x, "y": r.origin.y, "width": r.width, "height": r.height]
    }
    static func runningApp(_ args: [String: Any]) throws -> NSRunningApplication {
        if let pid = args["pid"] {
            let value = try integer(["pid": pid], "pid", default: 0, range: 1...Int(Int32.max))
            guard let app = NSRunningApplication(processIdentifier: pid_t(value)), !app.isTerminated else {
                throw PowerError.message("No running app has that pid")
            }
            return app
        }
        if let bundle = args["bundleId"] as? String {
            let matches = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
            guard matches.count == 1, let app = matches.first else {
                throw PowerError.message("Expected one running app for '\(bundle)'; found \(matches.count). Launch it or specify pid")
            }
            return app
        }
        guard let app = main({ NSWorkspace.shared.frontmostApplication }) else {
            throw PowerError.message("No foreground application")
        }
        return app
    }
    static func activate(_ app: NSRunningApplication) throws {
        _ = main { app.activate(options: [.activateIgnoringOtherApps]) }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if main({ NSWorkspace.shared.frontmostApplication?.processIdentifier }) == app.processIdentifier { return }
            Thread.sleep(forTimeInterval: 0.03)
        }
        throw PowerError.message("App did not become foreground; no input was sent")
    }
    static func ensureFrontmost(_ pid: pid_t) throws {
        guard main({ NSWorkspace.shared.frontmostApplication?.processIdentifier }) == pid else {
            throw PowerError.message("Foreground app changed; refresh the UI before continuing")
        }
    }
    static func permissions(_ args: [String: Any]) -> [String: Any] {
        let request = args["request"] as? Bool ?? false
        let accessibility = main {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: request] as CFDictionary)
        }
        let screen = CGPreflightScreenCaptureAccess()
        if request && !screen { _ = main { CGRequestScreenCaptureAccess() } }
        return ["ok": true, "accessibility": accessibility, "screenRecording": CGPreflightScreenCaptureAccess()]
    }
}

/// A callback can finish after an HTTP request times out. Keep its state synchronized.
final class PowerReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String: Any]?
    let ready = DispatchSemaphore(value: 0)
    func finish(_ result: [String: Any]) {
        lock.lock(); value = result; lock.unlock(); ready.signal()
    }
    func wait(seconds: Double) -> [String: Any] {
        guard ready.wait(timeout: .now() + seconds) == .success else {
            return ["ok": false, "error": "Operation timed out; its OS callback may still complete. Inspect state before retrying"]
        }
        lock.lock(); defer { lock.unlock() }
        return value ?? ["ok": false, "error": "Missing operation result"]
    }
}
