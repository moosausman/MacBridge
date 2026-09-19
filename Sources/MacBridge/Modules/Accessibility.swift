import Foundation
import AppKit
import ApplicationServices

/// Hashable wrapper around AXUIElement so it can live in a Set.
///
/// AXUIElement is a CFType: it has CFHash/CFEqual but no Swift Hashable
/// conformance, and identical elements can be distinct CF instances, so
/// pointer identity is not enough -- CFEqual is the correct comparison and
/// CFHash is consistent with it.
private struct AXElementKey: Hashable {
    let element: AXUIElement

    init(_ element: AXUIElement) { self.element = element }

    static func == (lhs: AXElementKey, rhs: AXElementKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

enum AccessibilityModule {
    struct Entry {
        let element: AXUIElement
        let pid: pid_t
        let created: Date
    }
    private static var cache: [String: Entry] = [:]
    private static let cacheLock = NSLock()

    static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
    static func string(_ element: AXUIElement, _ key: String) -> String? {
        attribute(element, key) as? String
    }
    static func elementAttribute(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = attribute(element, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = attribute(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    static func check(_ result: AXError, _ operation: String) throws {
        guard result == .success else {
            throw PowerError.message("\(operation) failed (AXError \(result.rawValue)). Refresh the snapshot; the app may not expose this control")
        }
    }
    static func entry(_ id: String) throws -> Entry {
        cacheLock.lock(); let item = cache[id]; cacheLock.unlock()
        guard let item, Date().timeIntervalSince(item.created) < 120 else {
            throw PowerError.message("Expired/unknown elementId. Request a fresh /ui/snapshot")
        }
        guard string(item.element, kAXRoleAttribute) != nil else {
            throw PowerError.message("Element disappeared. Request a fresh snapshot")
        }
        return item
    }
    private static func describe(_ element: AXUIElement) -> [String: Any] {
        var row: [String: Any] = [:]
        for (field, key) in [("role", kAXRoleAttribute), ("subrole", kAXSubroleAttribute),
                             ("title", kAXTitleAttribute), ("description", kAXDescriptionAttribute),
                             ("identifier", "AXIdentifier"), ("help", kAXHelpAttribute)] {
            if let text = string(element, key), !text.isEmpty { row[field] = String(text.prefix(4000)) }
        }
        let secure = string(element, kAXSubroleAttribute) == "AXSecureTextField"
        if secure { row["value"] = "[secure field]" }
        else if let text = string(element, kAXValueAttribute) { row["value"] = String(text.prefix(8000)) }
        else if let number = attribute(element, kAXValueAttribute) as? NSNumber { row["value"] = number }
        if let value = attribute(element, kAXEnabledAttribute) as? Bool { row["enabled"] = value }
        if let value = attribute(element, kAXFocusedAttribute) as? Bool { row["focused"] = value }
        if let r = frame(element) { row["frame"] = PowerSupport.rect(r) }
        row["actions"] = actions(element)
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success {
            row["valueSettable"] = settable.boolValue && !secure
        }
        return row
    }
    static func snapshot(args: [String: Any]) -> [String: Any] {
        PowerSupport.result {
            try PowerSupport.trusted()
            let app = try PowerSupport.runningApp(args)
            let maxNodes = try PowerSupport.integer(args, "maxNodes", default: 500, range: 1...1500)
            let maxDepth = try PowerSupport.integer(args, "maxDepth", default: 14, range: 1...30)
            let timeout = try PowerSupport.number(args, "timeout", default: 8, range: 0.5...15)
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.3)
            let snapshotId = UUID().uuidString, now = Date(), deadline = Date().addingTimeInterval(timeout)
            var queue: [(AXUIElement, Int, String?)] = [(root, 0, nil)]
            var cursor = 0, rows: [[String: Any]] = []
            // Hash-based membership instead of a linear scan. This was
            // `var visited: [AXUIElement]` checked with
            // `visited.contains(where: { CFEqual($0, element) })` -- an O(n)
            // walk per node, so O(n²) overall, with a CFEqual call at every
            // step. At the documented ceilings (1500 nodes, a queue up to
            // 4500) that's millions of CFEqual calls against a live
            // accessibility tree, and it ran inside the traversal deadline,
            // so on a big app (Xcode, a browser) the cost showed up as
            // snapshots coming back `truncated` rather than as slowness.
            var visited = Set<AXElementKey>()
            var newEntries: [String: Entry] = [:], truncated = false
            while cursor < queue.count && rows.count < maxNodes && Date() < deadline {
                let (element, depth, parent) = queue[cursor]; cursor += 1
                guard visited.insert(AXElementKey(element)).inserted else { continue }
                AXUIElementSetMessagingTimeout(element, 0.15)
                let id = snapshotId + ":" + String(rows.count)
                var row = describe(element)
                guard row["role"] != nil else { continue }
                row["elementId"] = id; row["depth"] = depth
                if let parent { row["parentId"] = parent }
                rows.append(row)
                newEntries[id] = Entry(element: element, pid: app.processIdentifier, created: now)
                if depth >= maxDepth { truncated = true; continue }
                // Copy bounded child slices rather than an unbounded entire chat history.
                var count: CFIndex = 0
                if AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success, count > 0 {
                    let room = max(0, maxNodes * 3 - queue.count)
                    let take = min(count, room)
                    if take < count { truncated = true }
                    if take > 0 {
                        var children: CFArray?
                        if AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, take, &children) == .success {
                            for child in children as? [AXUIElement] ?? [] { queue.append((child, depth + 1, id)) }
                        }
                    }
                }
            }
            truncated = truncated || cursor < queue.count
            cacheLock.lock()
            cache = cache.filter { now.timeIntervalSince($0.value.created) < 120 }
            if cache.count + newEntries.count > 6000 { cache.removeAll() }
            cache.merge(newEntries) { _, new in new }
            cacheLock.unlock()
            guard !rows.isEmpty else { throw PowerError.message("The app returned no accessibility elements") }
            return ["ok": true, "pid": Int(app.processIdentifier), "bundleId": app.bundleIdentifier ?? "",
                    "app": app.localizedName ?? "", "snapshotId": snapshotId, "expiresIn": 120,
                    "elements": rows, "truncated": truncated, "scope": "UI exposed by this app; not complete message history"]
        }
    }
    static func find(args: [String: Any]) -> [String: Any] {
        var result = snapshot(args: args)
        guard result["ok"] as? Bool == true, let rows = result["elements"] as? [[String: Any]] else { return result }
        let query = (args["query"] as? String ?? "").lowercased()
        let role = args["role"] as? String
        let exact = args["exact"] as? Bool ?? false
        result["elements"] = rows.filter { row in
            if let role, row["role"] as? String != role { return false }
            if query.isEmpty { return true }
            return ["title", "description", "value", "identifier", "help"].contains { key in
                guard let s = row[key] as? String else { return false }
                return exact ? s.lowercased() == query : s.lowercased().contains(query)
            }
        }
        return result
    }
    static func setText(_ entry: Entry, text: String) throws {
        guard string(entry.element, kAXSubroleAttribute) != "AXSecureTextField" else {
            throw PowerError.message("Secure text fields are excluded from text tools")
        }
        var writable = DarwinBoolean(false)
        try check(AXUIElementIsAttributeSettable(entry.element, kAXValueAttribute as CFString, &writable), "Check editable value")
        guard writable.boolValue else { throw PowerError.message("This element does not expose a writable value; inspect its actions or use existing keyboard tools after focusing it") }
        try check(AXUIElementSetAttributeValue(entry.element, kAXValueAttribute as CFString, text as CFString), "Set text")
        guard string(entry.element, kAXValueAttribute) == text else {
            throw PowerError.message("Text was submitted, but read-back differs; inspect the UI before proceeding")
        }
    }
    static func action(args: [String: Any]) -> [String: Any] {
        PowerSupport.result {
            try PowerSupport.trusted()
            let target = try entry(PowerSupport.text(args, "elementId"))
            let action = try PowerSupport.text(args, "action")
            if action == "setValue" {
                guard let text = args["text"] as? String, text.count <= 16000 else { throw PowerError.message("text must be a string of at most 16000 characters") }
                try setText(target, text: text)
                return ["ok": true, "verified": true]
            }
            if action == "focus" {
                try check(AXUIElementSetAttributeValue(target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue), "Focus")
            } else {
                guard actions(target.element).contains(action) else { throw PowerError.message("Action is not exposed by this element; choose one from its actions list") }
                try check(AXUIElementPerformAction(target.element, action as CFString), action)
            }
            return ["ok": true, "performed": action, "note": "Inspect a fresh snapshot to verify the app result"]
        }
    }
    static func activate(args: [String: Any]) -> [String: Any] {
        PowerSupport.result {
            let app = try PowerSupport.runningApp(args)
            try PowerSupport.activate(app)
            return ["ok": true, "pid": Int(app.processIdentifier), "bundleId": app.bundleIdentifier ?? ""]
        }
    }
    static func apps(args: [String: Any]) -> [String: Any] {
        let apps: [[String: Any]] = PowerSupport.main {
            NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map {
                ["pid": Int($0.processIdentifier), "name": $0.localizedName ?? "", "bundleId": $0.bundleIdentifier ?? "", "active": $0.isActive]
            }
        }
        return ["ok": true, "apps": apps]
    }
}
