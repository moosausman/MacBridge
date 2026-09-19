import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

enum ScreenModule {
    static func displays(args: [String: Any]) -> [String: Any] {
        PowerSupport.result {
            let items: [[String: Any]] = try PowerSupport.displays().map { id in
                ["displayId": Int(id), "main": id == CGMainDisplayID(),
                 "bounds": PowerSupport.rect(CGDisplayBounds(id)),
                 "pixelWidth": CGDisplayPixelsWide(id), "pixelHeight": CGDisplayPixelsHigh(id)]
            }
            return ["ok": true, "displays": items, "coordinateSpace": "global Quartz points; x right, y down; other displays may have negative coordinates"]
        }
    }
    static func capture(args: [String: Any]) -> [String: Any] {
        guard #available(macOS 14.0, *) else { return ["ok": false, "error": "Screenshots require macOS 14 or newer"] }
        return PowerSupport.result {
            guard CGPreflightScreenCaptureAccess() else { throw PowerError.message("Enable MacBridge in Privacy & Security > Screen Recording, then restart it") }
            let displayId = CGDirectDisplayID(try PowerSupport.integer(args, "displayId", default: Int(CGMainDisplayID()), range: 1...Int(UInt32.max)))
            guard try PowerSupport.displays().contains(displayId) else { throw PowerError.message("Unknown displayId") }
            let maxWidth = try PowerSupport.integer(args, "maxWidth", default: 1600, range: 320...3840)
            let box = PowerReplyBox()
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
                guard let display = content?.displays.first(where: { $0.displayID == displayId }) else {
                    box.finish(["ok": false, "error": error?.localizedDescription ?? "Display no longer available"]); return
                }
                let bounds = CGDisplayBounds(displayId)
                let width = min(maxWidth, display.width)
                let configuration = SCStreamConfiguration()
                configuration.width = width
                configuration.height = max(1, Int(Double(width) * bounds.height / bounds.width))
                configuration.showsCursor = args["cursor"] as? Bool ?? true
                let filter = SCContentFilter(display: display, excludingWindows: [])
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                    guard let image else {
                        box.finish(["ok": false, "error": error?.localizedDescription ?? "No screenshot returned"]); return
                    }
                    let rep = NSBitmapImageRep(cgImage: image)
                    guard let png = rep.representation(using: .png, properties: [:]) else {
                        box.finish(["ok": false, "error": "PNG encoding failed"]); return
                    }
                    box.finish(["ok": true, "mimeType": "image/png", "base64": png.base64EncodedString(),
                                "width": image.width, "height": image.height, "displayId": Int(displayId),
                                "bounds": PowerSupport.rect(bounds),
                                "pointPerPixelX": bounds.width / Double(image.width),
                                "pointPerPixelY": bounds.height / Double(image.height),
                                "mapping": "globalX = bounds.x + imageX * pointPerPixelX; globalY = bounds.y + imageY * pointPerPixelY"])
                }
            }
            return box.wait(seconds: 20)
        }
    }
}
