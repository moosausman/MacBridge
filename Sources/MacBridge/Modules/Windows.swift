// MacBridge/Sources/MacBridge/Modules/Windows.swift
// Owns: window discovery and arrangement (Accessibility API).
//
//   /windows/list       { app?: String (name or bundle id), pid?: Int }
//   /windows/focus      { pid, index?: Int, title?: String }
//   /windows/set-frame  { pid, index?|title?, x?, y?, width?, height? }
//   /windows/minimize   { pid, index?|title?, minimized: Bool }
//   /windows/close      { pid, index?|title? }
//   /windows/arrange    { layout: "left-half"|"right-half"|"maximize"|"center"|"top-half"|"bottom-half",
//                         pid, index?|title?, displayId? }
//
// Every mutation reads the window back afterwards and reports the frame
// it actually ended up with -- apps can refuse or clamp a resize, and a
// caller must not assume the requested frame was applied.

import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

enum WindowsModule {

    private static func axValue<T>(_ element: AXUIElement, _ attribute: String, _ type: AXValueType, _ empty: T) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var out = empty
        guard AXValueGetValue(value as! AXValue, type, &out) else { return nil }
        return out
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let origin = axValue(window, kAXPositionAttribute, .cgPoint, CGPoint.zero),
              let size = axValue(window, kAXSizeAttribute, .cgSize, CGSize.zero) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return (raw as? NSNumber)?.boolValue
    }

    private static func windows(of pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
              let list = raw as? [AXUIElement] else { return [] }
        // Finder exposes the desktop itself as an untitled full-screen
        // "window"; it can't be moved or closed, so it's not a real target.
        return list.filter { w in
            let role = string(w, kAXSubroleAttribute) ?? ""
            return role != "AXDesktop" && !(string(w, kAXTitleAttribute) ?? "").isEmpty || role == "AXStandardWindow"
        }
    }

    private static func describe(_ window: AXUIElement, index: Int, app: NSRunningApplication) -> [String: Any] {
        var row: [String: Any] = [
            "index": index, "pid": Int(app.processIdentifier), "app": app.localizedName ?? "",
            "bundleId": app.bundleIdentifier ?? "", "title": string(window, kAXTitleAttribute) ?? "",
            "minimized": bool(window, kAXMinimizedAttribute) ?? false,
            "main": bool(window, kAXMainAttribute) ?? false,
        ]
        if let f = frame(of: window) { row["frame"] = PowerSupport.rect(f) }
        return row
    }

    private static func apps(matching args: [String: Any]) throws -> [NSRunningApplication] {
        if args["pid"] != nil { return [try PowerSupport.runningApp(args)] }
        let all = PowerSupport.main { NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular } }
        if let name = (args["app"] as? String)?.lowercased(), !name.isEmpty {
            let hits = all.filter { ($0.localizedName ?? "").lowercased() == name || ($0.bundleIdentifier ?? "").lowercased() == name }
            let fuzzy = hits.isEmpty ? all.filter { ($0.localizedName ?? "").lowercased().contains(name) } : hits
            guard !fuzzy.isEmpty else { throw PowerError.message("No running app matches '\(name)'") }
            return fuzzy
        }
        return all
    }

    /// Resolves one window of `pid` by index or (case-insensitive) title substring.
    private static func target(_ args: [String: Any]) throws -> (NSRunningApplication, AXUIElement, Int) {
        let app = try PowerSupport.runningApp(args)
        let list = windows(of: app.processIdentifier)
        guard !list.isEmpty else { throw PowerError.message("\(app.localizedName ?? "That app") has no windows") }
        if let title = (args["title"] as? String)?.lowercased(), !title.isEmpty {
            guard let i = list.firstIndex(where: { (string($0, kAXTitleAttribute) ?? "").lowercased().contains(title) }) else {
                throw PowerError.message("No window titled like '\(title)'")
            }
            return (app, list[i], i)
        }
        let index = try PowerSupport.integer(args, "index", default: 0, range: 0...200)
        guard index < list.count else { throw PowerError.message("Window index out of range (0..\(list.count - 1))") }
        return (app, list[index], index)
    }

    static func list(args: [String: Any]) -> [String: Any] {
        PowerSupport.result {
            try PowerSupport.trusted()
            var rows: [[String: Any]] = []
            for app in try apps(matching: args) {
                for (i, w) in windows(of: app.processIdentifier).enumerated() {
                    rows.append(describe(w, index: i, app: app))
                }
            }
            return ["ok": true, "windows": rows, "count": rows.count]
        }
    }

    static func focus(args: [String: Any]) -> [String: Any] {
        PowerSupport.result {
            try PowerSupport.trusted()
            let (app, window, index) = try target(args)
            if bool(window, kAXMinimizedAttribute) == true {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            try PowerSupport.activate(app)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            return ["ok": true, "window": describe(window, index: index, app: app)]
        }
    }

    private static func apply(_ window: AXUIElement, _ rect: CGRect) throws {
        var origin = rect.origin, size = rect.size
        // Size, then position, then size again: some apps clamp position
        // based on the current size, others clamp size based on position.
        if let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v) }
        if let v = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v) }
        if let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v) }
    }

    static func setFrame(args: [String: Any]) -> [String: Any] {
        PowerSupport.result {
            try PowerSupport.trusted()
            let (app, window, index) = try target(args)
            guard let current = frame(of: window) else { throw PowerError.message("This window doesn't expose its frame") }
            let rect = CGRect(x: try PowerSupport.number(args, "x", default: current.origin.x),
                              y: try PowerSupport.number(args, "y", default: current.origin.y),
                              width: try PowerSupport.number(args, "width", default: current.width, range: 50...20000),
                              height: try PowerSupport.number(args, "height", default: current.height, range: 50...20000))
            try apply(window, rect)
            let actual = frame(of: window) ?? .zero
            let exact = abs(actual.origin.x - rect.origin.x) < 2 && abs(actual.origin.y - rect.origin.y) < 2
                && abs(actual.width - rect.width) < 2 && abs(actual.height - rect.height) < 2
            return ["ok": true, "requested": PowerSupport.rect(rect), "actual": PowerSupport.rect(actual),
                    "applied": exact, "window": describe(window, index: index, app: app)]
        }
    }

    static func arrange(args: [String: Any]) -> [String: Any] {
        PowerSupport.result {
            try PowerSupport.trusted()
            let layout = try PowerSupport.text(args, "layout", max: 40)
            let (app, window, index) = try target(args)
            let displayId = CGDirectDisplayID(try PowerSupport.integer(args, "displayId", default: Int(CGMainDisplayID()),
                                                                        range: 1...Int(UInt32.max)))
            // Visible frame (minus menu bar and Dock), converted from AppKit's
            // bottom-left origin to the top-left global space AX uses.
            let screens = PowerSupport.main { NSScreen.screens }
            guard let screen = screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayId
            }) ?? screens.first else { throw PowerError.message("No display") }
            let mainHeight = screens.first?.frame.height ?? screen.frame.height
            let vf = screen.visibleFrame
            let area = CGRect(x: vf.minX, y: mainHeight - vf.maxY, width: vf.width, height: vf.height)
            let rect: CGRect
            switch layout {
            case "left-half": rect = CGRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height)
            case "right-half": rect = CGRect(x: area.midX, y: area.minY, width: area.width / 2, height: area.height)
            case "top-half": rect = CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height / 2)
            case "bottom-half": rect = CGRect(x: area.minX, y: area.midY, width: area.width, height: area.height / 2)
            case "maximize": rect = area
            case "center":
                let current = frame(of: window) ?? CGRect(x: 0, y: 0, width: area.width * 0.6, height: area.height * 0.7)
                rect = CGRect(x: area.midX - current.width / 2, y: area.midY - current.height / 2,
                              width: current.width, height: current.height)
            default: throw PowerError.message("layout must be left-half, right-half, top-half, bottom-half, maximize or center")
            }
            let target = rect.integral
            try apply(window, target)
            let actual = frame(of: window) ?? .zero
            let applied = abs(actual.minX - target.minX) < 3 && abs(actual.minY - target.minY) < 3
                && abs(actual.width - target.width) < 3 && abs(actual.height - target.height) < 3
            var result: [String: Any] = ["ok": true, "layout": layout, "requested": PowerSupport.rect(target),
                                         "actual": PowerSupport.rect(actual), "applied": applied,
                                         "window": describe(window, index: index, app: app)]
            if !applied {
                result["note"] = "The app didn't accept that frame (fixed-size or desktop window, or a minimum size)."
            }
            return result
        }
    }

    static func minimize(args: [String: Any]) -> [String: Any] {
        PowerSupport.result {
            try PowerSupport.trusted()
            let (app, window, index) = try target(args)
            let minimized = args["minimized"] as? Bool ?? true
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString,
                                         minimized ? kCFBooleanTrue : kCFBooleanFalse)
            Thread.sleep(forTimeInterval: 0.3)
            return ["ok": true, "minimized": bool(window, kAXMinimizedAttribute) ?? minimized,
                    "window": describe(window, index: index, app: app)]
        }
    }

    static func close(args: [String: Any]) -> [String: Any] {
        PowerSupport.result {
            try PowerSupport.trusted()
            let (app, window, _) = try target(args)
            let title = string(window, kAXTitleAttribute) ?? ""
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &raw) == .success,
                  let button = raw, CFGetTypeID(button) == AXUIElementGetTypeID() else {
                throw PowerError.message("This window has no close button")
            }
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.4)
            let stillOpen = windows(of: app.processIdentifier).contains { (string($0, kAXTitleAttribute) ?? "") == title }
            return ["ok": true, "closed": !stillOpen, "title": title,
                    "note": stillOpen ? "The window is still open -- the app may be asking to save changes" : ""]
        }
    }
}
