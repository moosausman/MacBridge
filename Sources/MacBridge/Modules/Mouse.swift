import Foundation
import AppKit
import CoreGraphics

enum MouseModule {
    private static func location() throws -> CGPoint {
        guard let p = CGEvent(source: nil)?.location else { throw PowerError.message("Cannot read cursor") }
        return p
    }
    private static func button(_ args: [String: Any]) throws -> CGMouseButton {
        switch args["button"] as? String ?? "left" {
        case "left": return .left
        case "right": return .right
        case "middle": return .center
        default: throw PowerError.message("button must be left, right, or middle")
        }
    }
    private static func types(_ b: CGMouseButton) -> (CGEventType, CGEventType, CGEventType) {
        if b == .left { return (.leftMouseDown, .leftMouseUp, .leftMouseDragged) }
        if b == .right { return (.rightMouseDown, .rightMouseUp, .rightMouseDragged) }
        return (.otherMouseDown, .otherMouseUp, .otherMouseDragged)
    }
    private static func flags(_ args: [String: Any]) throws -> CGEventFlags {
        guard args["modifiers"] == nil || args["modifiers"] is [String] else {
            throw PowerError.message("modifiers must be a list of strings")
        }
        var result = CGEventFlags()
        for name in args["modifiers"] as? [String] ?? [] {
            switch name.lowercased() {
            case "command", "cmd": result.insert(.maskCommand)
            case "shift": result.insert(.maskShift)
            case "option", "alt": result.insert(.maskAlternate)
            case "control", "ctrl": result.insert(.maskControl)
            default: throw PowerError.message("Unknown modifier '\(name)'")
            }
        }
        return result
    }
    private static func post(_ type: CGEventType, _ point: CGPoint, _ b: CGMouseButton,
                             _ modifiers: CGEventFlags, count: Int64 = 1) throws {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: b) else {
            throw PowerError.message("Could not create mouse event")
        }
        event.flags = modifiers
        event.setIntegerValueField(.mouseEventClickState, value: count)
        event.post(tap: .cghidEventTap)
    }
    /// Upper-left corner of the main display is a physical escape gesture for animations.
    private static func checkAbort() throws {
        let p = try location(), bounds = CGDisplayBounds(CGMainDisplayID())
        if abs(p.x - bounds.minX) < 3 && abs(p.y - bounds.minY) < 3 {
            throw PowerError.message("Mouse animation stopped at the main display's upper-left corner; move the mouse away to resume")
        }
    }
    private static func animate(from: CGPoint, to: CGPoint, duration: Double,
                                type: CGEventType = .mouseMoved, button: CGMouseButton = .left,
                                modifiers: CGEventFlags = []) throws {
        let steps = max(1, Int(duration * 90))
        for i in 1...steps {
            try checkAbort()
            let t = Double(i) / Double(steps)
            let eased = t * t * (3 - 2 * t)
            let p = CGPoint(x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased)
            try post(type, p, button, modifiers)
            if duration > 0 { Thread.sleep(forTimeInterval: duration / Double(steps)) }
        }
    }
    static func position(args: [String: Any]) -> [String: Any] {
        PowerSupport.result {
            let p = try location()
            return ["ok": true, "x": p.x, "y": p.y, "coordinateSpace": "global Quartz points; origin top-left of main display"]
        }
    }
    static func move(args: [String: Any]) -> [String: Any] {
        PowerSupport.result {
            try PowerSupport.trusted()
            let p = try PowerSupport.point(args)
            let duration = try PowerSupport.number(args, "duration", default: 0.25, range: 0...5)
            try animate(from: location(), to: p, duration: duration, modifiers: flags(args))
            return ["ok": true, "posted": true, "x": p.x, "y": p.y]
        }
    }
    static func click(args: [String: Any]) -> [String: Any] {
        PowerSupport.result {
            try PowerSupport.trusted()
            let p = try ((args["x"] != nil || args["y"] != nil) ? PowerSupport.point(args) : location())
            let b = try button(args), f = try flags(args)
            let count = try PowerSupport.integer(args, "count", default: 1, range: 1...3)
            try checkAbort()
            try post(.mouseMoved, p, b, f)
            for index in 1...count {
                // Each down gets an up even if a later step fails.
                try post(types(b).0, p, b, f, count: Int64(index))
                Thread.sleep(forTimeInterval: 0.025)
                try post(types(b).1, p, b, f, count: Int64(index))
                if index < count { Thread.sleep(forTimeInterval: 0.07) }
            }
            return ["ok": true, "posted": true, "count": count, "x": p.x, "y": p.y]
        }
    }
    static func drag(args: [String: Any]) -> [String: Any] {
        PowerSupport.result {
            try PowerSupport.trusted()
            let start = try PowerSupport.point(args, x: "fromX", y: "fromY")
            let end = try PowerSupport.point(args, x: "toX", y: "toY")
            let duration = try PowerSupport.number(args, "duration", default: 0.6, range: 0.05...5)
            let b = try button(args), f = try flags(args), t = types(b)
            try checkAbort()
            try post(.mouseMoved, start, b, f)
            try post(t.0, start, b, f)
            defer { try? post(t.1, (try? location()) ?? end, b, f) }
            try animate(from: start, to: end, duration: duration, type: t.2, button: b, modifiers: f)
            return ["ok": true, "posted": true]
        }
    }
    static func scroll(args: [String: Any]) -> [String: Any] {
        PowerSupport.result {
            try PowerSupport.trusted()
            let dy = try PowerSupport.integer(args, "dy", default: 0, range: -10000...10000)
            let dx = try PowerSupport.integer(args, "dx", default: 0, range: -10000...10000)
            let units = args["unit"] as? String ?? "pixel"
            guard ["pixel", "line"].contains(units) else { throw PowerError.message("unit must be pixel or line") }
            let modifiers = try flags(args)
            let target = try ((args["x"] != nil || args["y"] != nil) ? PowerSupport.point(args) : location())
            try checkAbort()
            try post(.mouseMoved, target, .left, [])
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: units == "pixel" ? .pixel : .line,
                                      wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else {
                throw PowerError.message("Could not create scroll event")
            }
            event.flags = modifiers
            event.post(tap: .cghidEventTap)
            return ["ok": true, "posted": true, "note": "Positive dy scrolls up; negative dy scrolls down"]
        }
    }
}
