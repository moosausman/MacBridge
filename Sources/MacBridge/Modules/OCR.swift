// MacBridge/Sources/MacBridge/Modules/OCR.swift
// Owns: on-device text recognition (Vision). Nothing leaves the Mac.
//
//   /ocr/image   { path: String, languages?: [String], fast?: Bool }
//   /ocr/screen  { displayId?: Int, languages?: [String], fast?: Bool }
//
// Returns the recognised text in reading order plus one entry per line
// with its confidence and bounding box. For /ocr/screen the boxes are in
// global Quartz points, the same space /mouse/click takes, so a model can
// read the screen and then act on what it read.

import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit
import Vision

enum OCRModule {

    private static func recognize(_ image: CGImage, args: [String: Any]) throws -> [[String: Any]] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = (args["fast"] as? Bool ?? false) ? .fast : .accurate
        request.usesLanguageCorrection = true
        if let langs = args["languages"] as? [String], !langs.isEmpty {
            request.recognitionLanguages = langs
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        return observations.compactMap { obs -> [String: Any]? in
            guard let top = obs.topCandidates(1).first else { return nil }
            let box = obs.boundingBox  // normalized, origin bottom-left
            return ["text": top.string, "confidence": Double(top.confidence),
                    "box": ["x": box.minX, "y": 1 - box.maxY, "width": box.width, "height": box.height]]
        }
    }

    /// Lines in reading order: top to bottom, then left to right.
    private static func ordered(_ lines: [[String: Any]]) -> [[String: Any]] {
        lines.sorted {
            let a = $0["box"] as? [String: Double] ?? [:], b = $1["box"] as? [String: Double] ?? [:]
            let ay = a["y"] ?? 0, by = b["y"] ?? 0
            if abs(ay - by) > 0.01 { return ay < by }
            return (a["x"] ?? 0) < (b["x"] ?? 0)
        }
    }

    static func image(args: [String: Any]) -> [String: Any] {
        PowerSupport.result {
            let raw = try PowerSupport.text(args, "path", max: 4096)
            let path = (raw as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { throw PowerError.message("No file at \(path)") }
            guard let ns = NSImage(contentsOfFile: path),
                  let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw PowerError.message("Couldn't read an image from \(path) (use PNG, JPEG, HEIC, TIFF, GIF or a single-page PDF)")
            }
            let lines = ordered(try recognize(cg, args: args))
            return ["ok": true, "path": path, "text": lines.compactMap { $0["text"] as? String }.joined(separator: "\n"),
                    "lines": lines, "lineCount": lines.count, "imageWidth": cg.width, "imageHeight": cg.height,
                    "coordinateSpace": "box values are fractions of the image (0-1), origin top-left"]
        }
    }

    static func screen(args: [String: Any]) -> [String: Any] {
        guard #available(macOS 14.0, *) else { return ["ok": false, "error": "Screen OCR requires macOS 14 or newer"] }
        return PowerSupport.result {
            guard CGPreflightScreenCaptureAccess() else {
                throw PowerError.message("Enable MacBridge in Privacy & Security > Screen Recording, then restart it")
            }
            let displayId = CGDirectDisplayID(try PowerSupport.integer(args, "displayId", default: Int(CGMainDisplayID()),
                                                                        range: 1...Int(UInt32.max)))
            let box = PowerReplyBox()
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
                guard let display = content?.displays.first(where: { $0.displayID == displayId }) else {
                    box.finish(["ok": false, "error": error?.localizedDescription ?? "Display not available"]); return
                }
                let bounds = CGDisplayBounds(displayId)
                let config = SCStreamConfiguration()
                config.width = CGDisplayPixelsWide(displayId)
                config.height = CGDisplayPixelsHigh(displayId)
                config.showsCursor = false
                let filter = SCContentFilter(display: display, excludingWindows: [])
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                    guard let image else {
                        box.finish(["ok": false, "error": error?.localizedDescription ?? "No screenshot"]); return
                    }
                    do {
                        let lines = ordered(try recognize(image, args: args)).map { line -> [String: Any] in
                            var l = line
                            if let b = line["box"] as? [String: Double] {
                                l["globalBox"] = ["x": bounds.minX + (b["x"] ?? 0) * bounds.width,
                                                  "y": bounds.minY + (b["y"] ?? 0) * bounds.height,
                                                  "width": (b["width"] ?? 0) * bounds.width,
                                                  "height": (b["height"] ?? 0) * bounds.height]
                            }
                            return l
                        }
                        box.finish(["ok": true, "displayId": Int(displayId),
                                    "text": lines.compactMap { $0["text"] as? String }.joined(separator: "\n"),
                                    "lines": lines, "lineCount": lines.count,
                                    "coordinateSpace": "globalBox is in global Quartz points (use with /mouse/click)"])
                    } catch {
                        box.finish(["ok": false, "error": "Text recognition failed: \(error.localizedDescription)"])
                    }
                }
            }
            return box.wait(seconds: 30)
        }
    }
}
