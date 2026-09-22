// MacBridge/Sources/MacBridge/Modules/ScreenStream.swift
// Owns: a live, cheap view of this macOS session's screen, for Jugnu's
// "Desk" window -- the user watching the Jugnu account work in the
// background (or their own screen mirrored while a task runs).
//
//   /screen/stream/start {displayId?, maxWidth?, fps?, quality?}
//        -> { ok, width, height, bounds, pointPerPixelX/Y, seq }
//   /screen/stream/frame {since?, waitMs?}
//        -> { ok, seq, base64, mimeType, width, height } | { ok, unchanged: true, seq }
//   /screen/stream/stop -> { ok }
//
// /screen/capture spins up a whole capture session per shot (a few hundred
// milliseconds), which is fine for one screenshot and hopeless for live
// viewing. This keeps ONE SCStream running and hands out its latest frame,
// so a frame costs a JPEG encode instead of a new session.
//
// The frame request long-polls: it waits (briefly) for a frame newer than
// the caller's, so a still screen sends nothing and a busy one streams at
// the configured rate without the client guessing when to ask.
//
// The stream stops itself once nobody has asked for a frame in a while --
// closing the Desk window must never leave a capture running forever.

import Foundation
import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import ScreenCaptureKit

enum ScreenStreamModule {

    static func start(args: [String: Any]) -> [String: Any] {
        guard #available(macOS 14.0, *) else { return ["ok": false, "error": "Live view requires macOS 14 or newer"] }
        return PowerSupport.result {
            guard CGPreflightScreenCaptureAccess() else {
                throw PowerError.message("Enable MacBridge in Privacy & Security > Screen Recording, then restart it")
            }
            let displayId = CGDirectDisplayID(try PowerSupport.integer(args, "displayId",
                                                                      default: Int(CGMainDisplayID()),
                                                                      range: 1...Int(UInt32.max)))
            guard try PowerSupport.displays().contains(displayId) else { throw PowerError.message("Unknown displayId") }
            let maxWidth = try PowerSupport.integer(args, "maxWidth", default: 900, range: 320...3840)
            let fps = try PowerSupport.integer(args, "fps", default: 6, range: 1...30)
            let quality = try PowerSupport.number(args, "quality", default: 0.5, range: 0.1...1.0)
            return try ScreenFeed.shared.start(displayId: displayId, maxWidth: maxWidth, fps: fps, quality: quality)
        }
    }

    static func frame(args: [String: Any]) -> [String: Any] {
        guard #available(macOS 14.0, *) else { return ["ok": false, "error": "Live view requires macOS 14 or newer"] }
        return PowerSupport.result {
            let since = try PowerSupport.integer(args, "since", default: 0, range: 0...Int.max)
            let waitMs = try PowerSupport.integer(args, "waitMs", default: 1000, range: 0...5000)
            return try ScreenFeed.shared.frame(since: since, waitMs: waitMs)
        }
    }

    static func stop(args: [String: Any]) -> [String: Any] {
        guard #available(macOS 14.0, *) else { return ["ok": true] }
        ScreenFeed.shared.stop()
        return ["ok": true]
    }
}

/// The one running capture, and the latest frame it produced.
@available(macOS 14.0, *)
final class ScreenFeed: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let shared = ScreenFeed()

    /// Stop capturing when no frame has been asked for in this long -- the
    /// Desk window was closed, or the app quit without saying so.
    private static let idleTimeout: TimeInterval = 20

    private let condition = NSCondition()
    private let queue = DispatchQueue(label: "ai.jugnu.screenfeed")
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    private var stream: SCStream?
    private var latest: Data?
    private var seq = 0
    private var frameSize = CGSize.zero
    private var bounds = CGRect.zero
    private var displayId: CGDirectDisplayID = 0
    private var quality = 0.5
    private var lastAsked = Date()
    private var janitor: DispatchSourceTimer?

    // MARK: Control

    func start(displayId: CGDirectDisplayID, maxWidth: Int, fps: Int, quality: Double) throws -> [String: Any] {
        condition.lock()
        let alreadyRunning = stream != nil && self.displayId == displayId
        self.quality = quality
        lastAsked = Date()
        condition.unlock()
        if alreadyRunning { return info() }

        stop()
        let box = PowerReplyBox()
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            guard let display = content?.displays.first(where: { $0.displayID == displayId }) else {
                box.finish(["ok": false, "error": error?.localizedDescription ?? "Display no longer available"])
                return
            }
            let displayBounds = CGDisplayBounds(displayId)
            let width = min(maxWidth, display.width)
            let height = max(1, Int(Double(width) * displayBounds.height / displayBounds.width))
            let configuration = SCStreamConfiguration()
            configuration.width = width
            configuration.height = height
            configuration.showsCursor = true          // seeing where Jugnu's pointer is IS the point
            configuration.queueDepth = 3
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
            do {
                try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
            } catch {
                box.finish(["ok": false, "error": "Couldn't attach to the display: \(error.localizedDescription)"])
                return
            }
            newStream.startCapture { error in
                if let error {
                    box.finish(["ok": false, "error": error.localizedDescription])
                    return
                }
                self.condition.lock()
                self.stream = newStream
                self.displayId = displayId
                self.bounds = displayBounds
                self.frameSize = CGSize(width: width, height: height)
                self.lastAsked = Date()
                self.condition.unlock()
                self.startJanitor()
                box.finish(self.info())
            }
        }
        let result = box.wait(seconds: 15)
        if result["ok"] as? Bool != true {
            throw PowerError.message(String(describing: result["error"] ?? "Couldn't start the live view"))
        }
        return result
    }

    func stop() {
        condition.lock()
        let running = stream
        stream = nil
        latest = nil
        condition.unlock()
        janitor?.cancel()
        janitor = nil
        running?.stopCapture { _ in }
    }

    /// The latest frame, waiting up to `waitMs` for one newer than `since`.
    func frame(since: Int, waitMs: Int) throws -> [String: Any] {
        condition.lock()
        defer { condition.unlock() }
        lastAsked = Date()
        guard stream != nil else {
            throw PowerError.message("The live view isn't running. Call /screen/stream/start first.")
        }
        let deadline = Date().addingTimeInterval(Double(waitMs) / 1000.0)
        while seq <= since, latest != nil || seq == 0 {
            if !condition.wait(until: deadline) { break }
            if stream == nil { throw PowerError.message("The live view stopped.") }
        }
        guard let data = latest, seq > since else {
            return ["ok": true, "unchanged": true, "seq": seq]
        }
        return ["ok": true, "seq": seq, "mimeType": "image/jpeg", "base64": data.base64EncodedString(),
                "width": Int(frameSize.width), "height": Int(frameSize.height),
                "bounds": PowerSupport.rect(bounds),
                "pointPerPixelX": frameSize.width > 0 ? bounds.width / frameSize.width : 1,
                "pointPerPixelY": frameSize.height > 0 ? bounds.height / frameSize.height : 1,
                "mapping": "globalX = bounds.x + imageX * pointPerPixelX; globalY = bounds.y + imageY * pointPerPixelY"]
    }

    private func info() -> [String: Any] {
        ["ok": true, "seq": seq, "displayId": Int(displayId),
         "width": Int(frameSize.width), "height": Int(frameSize.height),
         "bounds": PowerSupport.rect(bounds),
         "pointPerPixelX": frameSize.width > 0 ? bounds.width / frameSize.width : 1,
         "pointPerPixelY": frameSize.height > 0 ? bounds.height / frameSize.height : 1]
    }

    private func startJanitor() {
        janitor?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.condition.lock()
            let idle = Date().timeIntervalSince(self.lastAsked) > Self.idleTimeout && self.stream != nil
            self.condition.unlock()
            if idle { self.stop() }
        }
        timer.resume()
        janitor = timer
    }

    // MARK: Frames

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Frames whose status isn't "complete" carry no new pixels (the
        // screen didn't change, or the frame was dropped).
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw), status != .complete {
            return
        }
        condition.lock()
        let quality = self.quality
        condition.unlock()

        let image = CIImage(cvPixelBuffer: pixels)
        guard let data = context.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(),
                                                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality])
        else { return }

        condition.lock()
        latest = data
        seq += 1
        condition.broadcast()
        condition.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        condition.lock()
        self.stream = nil
        condition.broadcast()
        condition.unlock()
    }
}
