// MacBridge/Sources/MacBridge/Modules/Finder.swift
// Owns: AppKit's NSWorkspace (file/Finder interaction).
// Exposes static functions returning JSON-safe [String: Any] dictionaries.
// Knows nothing about HTTP — Router.swift is the only caller.

import Foundation
import AppKit

enum Finder {

    /// args: { "path": String }  — opens the file/folder/URL with its default app.
    static func open(args: [String: Any]) -> [String: Any] {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return ["ok": false, "error": "'path' is required"]
        }

        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)

        guard FileManager.default.fileExists(atPath: expanded) else {
            return ["ok": false, "error": "No file or folder exists at \(path)"]
        }

        let success = NSWorkspace.shared.open(url)
        guard success else {
            return ["ok": false, "error": "Failed to open \(path)"]
        }
        return ["ok": true, "path": expanded]
    }

    /// args: { "path": String }  — reveals the file in a Finder window, selected.
    static func reveal(args: [String: Any]) -> [String: Any] {
        guard let path = args["path"] as? String, !path.isEmpty else {
            return ["ok": false, "error": "'path' is required"]
        }

        let expanded = (path as NSString).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: expanded) else {
            return ["ok": false, "error": "No file or folder exists at \(path)"]
        }

        NSWorkspace.shared.selectFile(expanded, inFileViewerRootedAtPath: "")
        return ["ok": true, "path": expanded]
    }
}
