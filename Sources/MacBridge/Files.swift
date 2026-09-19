// MacBridge/Sources/MacBridge/Modules/Files.swift
// Owns: Foundation's FileManager (raw filesystem operations).
// Distinct from Finder.swift, which is about the GUI (opening/revealing
// files in Finder windows) — this module reads/writes bytes directly.
// Exposes static functions returning JSON-safe [String: Any] dictionaries.
// Knows nothing about HTTP — Router.swift is the only caller.

import Foundation
import CryptoKit

enum Files {

    // MARK: - Helpers

    private static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private static func requirePath(_ args: [String: Any]) -> String? {
        guard let path = args["path"] as? String, !path.isEmpty else { return nil }
        return path
    }

    /// Best-effort categorization bucket for a file extension.
    private static func category(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "bmp", "tiff", "svg":
            return "images"
        case "mp4", "mov", "avi", "mkv", "webm", "m4v":
            return "video"
        case "mp3", "wav", "aac", "flac", "m4a", "aiff":
            return "audio"
        case "pdf", "doc", "docx", "pages", "txt", "rtf", "odt":
            return "documents"
        case "xls", "xlsx", "numbers", "csv":
            return "spreadsheets"
        case "ppt", "pptx", "key":
            return "presentations"
        case "zip", "tar", "gz", "rar", "7z", "dmg":
            return "archives"
        case "swift", "py", "js", "ts", "tsx", "jsx", "java", "c", "cpp", "h", "m",
             "go", "rs", "rb", "php", "sh", "json", "yml", "yaml", "html", "css":
            return "code"
        case "":
            return "other"
        default:
            return "other"
        }
    }

    /// Returns metadata dict for a single filesystem item. Returns nil if it
    /// can't be stat'd (e.g. permission denied).
    private static func metadata(atPath fullPath: String, name: String) -> [String: Any]? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fullPath) else { return nil }

        var isDirectory = (attrs[.type] as? FileAttributeType) == .typeDirectory
        let size = attrs[.size] as? Int ?? 0
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
        let created = (attrs[.creationDate] as? Date)?.timeIntervalSince1970
        let ext = (name as NSString).pathExtension

        // FIX: attributesOfItem describes the symlink itself, not whatever
        // it points to — so a symlink pointing at a directory was silently
        // falling through the `!isDirectory` branch below and getting
        // categorized as a regular "other" file, and would never be
        // recursed into or grouped as a directory anywhere in this file.
        // destinationOfSymbolicLink only succeeds for actual symlinks, so
        // this is a safe, explicit probe regardless of what attributesOfItem
        // itself reports. fileExists(atPath:isDirectory:) follows the link
        // to find out what it actually resolves to; a dangling symlink
        // leaves isDirectory at its own (non-directory) type.
        var isSymlink = false
        var symlinkTarget: String? = nil
        if let target = try? fm.destinationOfSymbolicLink(atPath: fullPath) {
            isSymlink = true
            symlinkTarget = target
            var targetIsDirectory: ObjCBool = false
            if fm.fileExists(atPath: fullPath, isDirectory: &targetIsDirectory) {
                isDirectory = targetIsDirectory.boolValue
            }
        }

        var dict: [String: Any] = [
            "name": name,
            "path": fullPath,
            "isDirectory": isDirectory,
            "size": size,
        ]
        if let modified { dict["modified"] = modified }
        if let created { dict["created"] = created }
        if isSymlink {
            dict["isSymlink"] = true
            if let symlinkTarget { dict["symlinkTarget"] = symlinkTarget }
        }
        if !isDirectory {
            dict["extension"] = ext
            dict["category"] = category(forExtension: ext)
        }
        return dict
    }

    /// Splits text into lines the way line-oriented tools (e.g. `wc -l`,
    /// editors) count them: a single trailing newline terminates the last
    /// line rather than starting a new, empty one.
    ///
    /// FIX: plain `text.components(separatedBy: "\n")` reports one extra
    /// phantom empty "line" for any normally newline-terminated file (e.g.
    /// "a\nb\n" -> ["a","b",""], 3 elements instead of 2). That extra
    /// element was silently inflating totalLines in readRange(), tripping
    /// the truncated-by-lines flag one line early in preview()/head() for
    /// files with exactly `maxLines` real lines, miscounting the last
    /// window in tail(), and introducing a bogus one-line diff in diff()
    /// whenever exactly one of the two files ended with a trailing newline.
    private static func splitLines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    // MARK: - Read / Write

    /// args: { "path": String }
    static func read(args: [String: Any]) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }

        let fullPath = expand(path)

        guard let data = FileManager.default.contents(atPath: fullPath) else {
            return ["ok": false, "error": "Could not read file at \(path)"]
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return ["ok": false, "error": "File at \(path) is not valid UTF-8 text"]
        }

        return ["ok": true, "content": text]
    }

    /// args: { "path": String, "content": String, "overwrite": Bool? (default false), "createIntermediateDirectories": Bool? (default true) }
    static func write(args: [String: Any]) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }
        guard let content = args["content"] as? String else {
            return ["ok": false, "error": "'content' is required"]
        }

        let fullPath = expand(path)
        let overwrite = args["overwrite"] as? Bool ?? false
        let createIntermediate = args["createIntermediateDirectories"] as? Bool ?? true

        if !overwrite && FileManager.default.fileExists(atPath: fullPath) {
            return ["ok": false, "error": "File already exists at \(path) — pass overwrite: true to replace it"]
        }

        if createIntermediate {
            let dir = (fullPath as NSString).deletingLastPathComponent
            if !dir.isEmpty && !FileManager.default.fileExists(atPath: dir) {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
        }

        do {
            try content.write(toFile: fullPath, atomically: true, encoding: .utf8)
            return ["ok": true, "path": fullPath]
        } catch {
            return ["ok": false, "error": "Failed to write file: \(error.localizedDescription)"]
        }
    }

    /// args: { "path": String, "content": String, "createIfMissing": Bool? (default true) }
    /// Appends to an existing file, or creates it (and any intermediate
    /// directories, via write()) if it doesn't exist yet. write() only ever
    /// replaces or refuses — this is the missing "add to the end" mode.
    static func append(args: [String: Any]) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }
        guard let content = args["content"] as? String else {
            return ["ok": false, "error": "'content' is required"]
        }
        let fullPath = expand(path)
        let createIfMissing = args["createIfMissing"] as? Bool ?? true
        let fm = FileManager.default

        if !fm.fileExists(atPath: fullPath) {
            guard createIfMissing else {
                return ["ok": false, "error": "No file exists at \(path) — pass createIfMissing: true to create it"]
            }
            return write(args: ["path": path, "content": content, "overwrite": false])
        }

        guard let data = content.data(using: .utf8) else {
            return ["ok": false, "error": "Content could not be encoded as UTF-8"]
        }
        guard let handle = FileHandle(forWritingAtPath: fullPath) else {
            return ["ok": false, "error": "Could not open \(path) for writing"]
        }
        defer { try? handle.close() }

        do {
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return ["ok": true, "path": fullPath]
        } catch {
            return ["ok": false, "error": "Failed to append to \(path): \(error.localizedDescription)"]
        }
    }

    /// args: { "path": String }
    /// Creates an empty file if none exists, or bumps the modification date
    /// to now if it already does — same idea as the `touch` CLI command.
    static func touch(args: [String: Any]) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }
        let fullPath = expand(path)
        let fm = FileManager.default

        if !fm.fileExists(atPath: fullPath) {
            return write(args: ["path": path, "content": ""])
        }

        do {
            try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: fullPath)
            return ["ok": true, "path": fullPath]
        } catch {
            return ["ok": false, "error": "Failed to update modification date: \(error.localizedDescription)"]
        }
    }

    // MARK: - Directory creation

    /// args: { "path": String, "createIntermediateDirectories": Bool? (default true) }
    static func mkdir(args: [String: Any]) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }

        let fullPath = expand(path)
        let intermediate = args["createIntermediateDirectories"] as? Bool ?? true

        if FileManager.default.fileExists(atPath: fullPath) {
            return ["ok": false, "error": "Something already exists at \(path)"]
        }

        do {
            try FileManager.default.createDirectory(atPath: fullPath, withIntermediateDirectories: intermediate)
            return ["ok": true, "path": fullPath]
        } catch {
            return ["ok": false, "error": "Failed to create directory: \(error.localizedDescription)"]
        }
    }

    // MARK: - Move / Copy / Rename

    /// args: { "from": String, "to": String, "overwrite": Bool? (default false) }
    /// Rename is just a move within the same parent directory — same function.
    static func move(args: [String: Any]) -> [String: Any] {
        guard let from = args["from"] as? String, !from.isEmpty else {
            return ["ok": false, "error": "'from' is required"]
        }
        guard let to = args["to"] as? String, !to.isEmpty else {
            return ["ok": false, "error": "'to' is required"]
        }

        let fullFrom = expand(from)
        let fullTo = expand(to)
        let overwrite = args["overwrite"] as? Bool ?? false
        let fm = FileManager.default

        guard fm.fileExists(atPath: fullFrom) else {
            return ["ok": false, "error": "No file or folder exists at \(from)"]
        }

        if fm.fileExists(atPath: fullTo) {
            if !overwrite {
                return ["ok": false, "error": "Something already exists at \(to) — pass overwrite: true to replace it"]
            }
            try? fm.removeItem(atPath: fullTo)
        }

        let destDir = (fullTo as NSString).deletingLastPathComponent
        if !destDir.isEmpty && !fm.fileExists(atPath: destDir) {
            try? fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        }

        do {
            try fm.moveItem(atPath: fullFrom, toPath: fullTo)
            return ["ok": true, "path": fullTo]
        } catch {
            return ["ok": false, "error": "Failed to move: \(error.localizedDescription)"]
        }
    }

    /// args: { "from": String, "to": String, "overwrite": Bool? (default false) }
    static func copy(args: [String: Any]) -> [String: Any] {
        guard let from = args["from"] as? String, !from.isEmpty else {
            return ["ok": false, "error": "'from' is required"]
        }
        guard let to = args["to"] as? String, !to.isEmpty else {
            return ["ok": false, "error": "'to' is required"]
        }

        let fullFrom = expand(from)
        let fullTo = expand(to)
        let overwrite = args["overwrite"] as? Bool ?? false
        let fm = FileManager.default

        guard fm.fileExists(atPath: fullFrom) else {
            return ["ok": false, "error": "No file or folder exists at \(from)"]
        }

        if fm.fileExists(atPath: fullTo) {
            if !overwrite {
                return ["ok": false, "error": "Something already exists at \(to) — pass overwrite: true to replace it"]
            }
            try? fm.removeItem(atPath: fullTo)
        }

        let destDir = (fullTo as NSString).deletingLastPathComponent
        if !destDir.isEmpty && !fm.fileExists(atPath: destDir) {
            try? fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        }

        do {
            try fm.copyItem(atPath: fullFrom, toPath: fullTo)
            return ["ok": true, "path": fullTo]
        } catch {
            return ["ok": false, "error": "Failed to copy: \(error.localizedDescription)"]
        }
    }

    /// args: { "path": String }
    /// Finder-style "Make a copy": duplicates the item into its own parent
    /// directory under an auto-generated "name copy" / "name copy 2" name,
    /// rather than requiring the caller to name the destination like copy() does.
    static func duplicate(args: [String: Any]) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }
        let fullPath = expand(path)
        let fm = FileManager.default

        guard fm.fileExists(atPath: fullPath) else {
            return ["ok": false, "error": "No file or folder exists at \(path)"]
        }

        let dir = (fullPath as NSString).deletingLastPathComponent
        let name = (fullPath as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension

        func candidateName(_ suffix: String) -> String {
            ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)"
        }

        var destination = (dir as NSString).appendingPathComponent(candidateName(" copy"))
        var attempt = 2
        while fm.fileExists(atPath: destination) {
            destination = (dir as NSString).appendingPathComponent(candidateName(" copy \(attempt)"))
            attempt += 1
        }

        do {
            try fm.copyItem(atPath: fullPath, toPath: destination)
            return ["ok": true, "path": destination]
        } catch {
            return ["ok": false, "error": "Failed to duplicate: \(error.localizedDescription)"]
        }
    }

    // MARK: - Delete

    /// args: { "path": String, "recursive": Bool? (default true) }
    /// `recursive: false` is a safety rail: refuses to delete a non-empty
    /// directory instead of silently nuking it.
    static func delete(args: [String: Any]) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }

        let fullPath = expand(path)
        let recursive = args["recursive"] as? Bool ?? true
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else {
            return ["ok": false, "error": "No file or folder exists at \(path)"]
        }

        if isDir.boolValue && !recursive {
            let contents = (try? fm.contentsOfDirectory(atPath: fullPath)) ?? []
            if !contents.isEmpty {
                return ["ok": false, "error": "\(path) is a non-empty directory — pass recursive: true to delete it anyway"]
            }
        }

        do {
            try fm.removeItem(atPath: fullPath)
            return ["ok": true, "path": fullPath]
        } catch {
            return ["ok": false, "error": "Failed to delete: \(error.localizedDescription)"]
        }
    }

    // MARK: - Existence / Info

    /// args: { "path": String }
    static func exists(args: [String: Any]) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }

        let fullPath = expand(path)
        var isDir: ObjCBool = false
        let found = FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir)

        return ["ok": true, "exists": found, "isDirectory": found ? isDir.boolValue : false]
    }

    /// args: { "path": String } — metadata for a single file or folder.
    static func info(args: [String: Any]) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }

        let fullPath = expand(path)
        let name = (fullPath as NSString).lastPathComponent

        guard let meta = metadata(atPath: fullPath, name: name) else {
            return ["ok": false, "error": "Could not stat \(path)"]
        }

        return ["ok": true, "info": meta]
    }

    // MARK: - Listing

    /// args: { "path": String, "recursive": Bool? (default false), "maxDepth": Int? (default 5), "maxItems": Int? (default 2000) }
    ///
    /// NOTE: both recursive and non-recursive modes return metadata dicts
    /// (name/path/isDirectory/size/modified/created/extension/category,
    /// plus isSymlink/symlinkTarget when the item is a symlink), not bare
    /// filename strings. Every downstream consumer of list() (group,
    /// search, summarizeFolder, recentFiles/largestFiles,
    /// emptyFiles/emptyDirectories, fuzzySearch, brokenSymlinks) casts
    /// "items" to [[String: Any]] and depends on this. A prior version
    /// returned bare strings in non-recursive mode, which silently broke
    /// all of those callers whenever `recursive: false` was passed
    /// explicitly.
    static func list(args: [String: Any]) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }

        let fullPath = expand(path)
        let recursive = args["recursive"] as? Bool ?? false
        let fm = FileManager.default
        let maxItems = args["maxItems"] as? Int ?? 2000

        if !recursive {
            let names: [String]
            do {
                names = try fm.contentsOfDirectory(atPath: fullPath)
            } catch {
                return ["ok": false, "error": "Failed to list directory: \(error.localizedDescription)"]
            }

            var results: [[String: Any]] = []
            var truncated = false
            for name in names.sorted() {
                if results.count >= maxItems {
                    truncated = true
                    break
                }
                let itemFullPath = (fullPath as NSString).appendingPathComponent(name)
                if let meta = metadata(atPath: itemFullPath, name: name) {
                    results.append(meta)
                }
            }

            var response: [String: Any] = ["ok": true, "items": results, "count": results.count]
            if truncated { response["truncated"] = true }
            return response
        }

        // Recursive walk with hard caps so an agent can't accidentally
        // request a metadata dump of the whole home directory.
        let maxDepth = args["maxDepth"] as? Int ?? 5

        guard let enumerator = fm.enumerator(atPath: fullPath) else {
            return ["ok": false, "error": "Failed to list directory: could not enumerate \(path)"]
        }

        var results: [[String: Any]] = []
        var truncated = false

        for case let relativePath as String in enumerator {
            let depth = relativePath.components(separatedBy: "/").count
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            if results.count >= maxItems {
                truncated = true
                break
            }
            let itemFullPath = (fullPath as NSString).appendingPathComponent(relativePath)
            let name = (relativePath as NSString).lastPathComponent
            if let meta = metadata(atPath: itemFullPath, name: name) {
                var m = meta
                m["relativePath"] = relativePath
                results.append(m)
            }
        }

        var response: [String: Any] = ["ok": true, "items": results, "count": results.count]
        if truncated { response["truncated"] = true }
        return response
    }

    // MARK: - Grouping by content

    /// args: { "path": String, "by": String ("type" | "duplicates"), "recursive": Bool? (default true), "maxDepth": Int? (default 5), "maxItems": Int? (default 2000) }
    ///
    /// "type": buckets files by extension-derived category (images, documents,
    /// code, etc.) — the common "clean up this folder" use case.
    ///
    /// "duplicates": groups files by content hash (SHA-256), so an agent can
    /// find and offer to remove true duplicates regardless of filename.
    static func group(args: [String: Any]) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }
        let by = args["by"] as? String ?? "type"
        guard by == "type" || by == "duplicates" else {
            return ["ok": false, "error": "'by' must be 'type' or 'duplicates'"]
        }

        let listResult = list(args: [
            "path": path,
            "recursive": args["recursive"] as? Bool ?? true,
            "maxDepth": args["maxDepth"] as? Int ?? 5,
            "maxItems": args["maxItems"] as? Int ?? 2000,
        ])

        guard listResult["ok"] as? Bool == true, let items = listResult["items"] as? [[String: Any]] else {
            return listResult
        }

        let files = items.filter { ($0["isDirectory"] as? Bool) == false }

        if by == "type" {
            var groups: [String: [[String: Any]]] = [:]
            for file in files {
                let cat = file["category"] as? String ?? "other"
                groups[cat, default: []].append(file)
            }
            var response: [String: Any] = ["ok": true, "by": "type", "groups": groups]
            if listResult["truncated"] != nil { response["truncated"] = true }
            return response
        }

        // by == "duplicates": hash file contents, group by hash, drop singletons.
        var hashGroups: [String: [[String: Any]]] = [:]
        var skipped: [String] = []
        let maxHashBytes = 50 * 1024 * 1024 // skip files over 50MB to keep this fast

        for file in files {
            guard let fullPath = file["path"] as? String,
                  let size = file["size"] as? Int else { continue }
            if size > maxHashBytes {
                skipped.append(fullPath)
                continue
            }
            guard let data = FileManager.default.contents(atPath: fullPath) else {
                skipped.append(fullPath)
                continue
            }
            let digest = SHA256.hash(data: data)
            let hashString = digest.map { String(format: "%02x", $0) }.joined()
            hashGroups[hashString, default: []].append(file)
        }

        let duplicateGroups = hashGroups.values.filter { $0.count > 1 }

        var response: [String: Any] = [
            "ok": true,
            "by": "duplicates",
            "groups": duplicateGroups,
            "duplicateSetCount": duplicateGroups.count,
        ]
        if !skipped.isEmpty { response["skipped"] = skipped }
        if listResult["truncated"] != nil { response["truncated"] = true }
        return response
    }

    // MARK: - Search

    /// args: { "path": String, "namePattern": String?, "contains": String?, "recursive": Bool? (default true), "maxDepth": Int? (default 5), "maxItems": Int? (default 2000), "maxMatches": Int? (default 200) }
    ///
    /// namePattern matches against filename (case-insensitive substring match).
    /// contains does a UTF-8 text search inside file bodies (grep-like) —
    /// binary/non-UTF8 files are silently skipped rather than erroring out.
    static func search(args: [String: Any]) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }
        let namePattern = (args["namePattern"] as? String)?.lowercased()
        let contains = args["contains"] as? String
        guard namePattern != nil || contains != nil else {
            return ["ok": false, "error": "At least one of 'namePattern' or 'contains' is required"]
        }
        let maxMatches = args["maxMatches"] as? Int ?? 200

        let listResult = list(args: [
            "path": path,
            "recursive": args["recursive"] as? Bool ?? true,
            "maxDepth": args["maxDepth"] as? Int ?? 5,
            "maxItems": args["maxItems"] as? Int ?? 2000,
        ])

        guard listResult["ok"] as? Bool == true, let items = listResult["items"] as? [[String: Any]] else {
            return listResult
        }

        var matches: [[String: Any]] = []

        for item in items {
            guard let name = item["name"] as? String,
                  let fullPath = item["path"] as? String,
                  (item["isDirectory"] as? Bool) == false else { continue }

            if let namePattern, !name.lowercased().contains(namePattern) {
                continue
            }

            if let contains {
                guard let data = FileManager.default.contents(atPath: fullPath),
                      let text = String(data: data, encoding: .utf8),
                      text.localizedCaseInsensitiveContains(contains) else {
                    continue
                }
            }

            matches.append(item)
            if matches.count >= maxMatches { break }
        }

        return ["ok": true, "matches": matches, "count": matches.count]
    }

    // MARK: - Partial Reads

    /// args: { "path": String, "maxLines": Int? (default 50), "maxBytes": Int? (default 65536) }
    /// Reads only the first slice of a file — the safety rail for "let me
    /// peek before deciding to load this fully". Whichever limit hits first wins.
    static func preview(args: [String: Any]) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }
        let fullPath = expand(path)
        let maxLines = args["maxLines"] as? Int ?? 50
        let maxBytes = args["maxBytes"] as? Int ?? 65536

        guard let handle = FileHandle(forReadingAtPath: fullPath) else {
            return ["ok": false, "error": "Could not open file at \(path)"]
        }
        defer { try? handle.close() }

        // NOTE: read(upToCount:) returns Data? AND can throw. Using `try?`
        // here would flatten Data?? to Data?, making a real I/O error
        // indistinguishable from a legitimate empty read at EOF (e.g. an
        // empty file). Handle the throw and the nil-at-EOF case separately
        // so empty files preview correctly instead of reporting failure.
        let chunk: Data
        do {
            chunk = try handle.read(upToCount: maxBytes) ?? Data()
        } catch {
            return ["ok": false, "error": "Failed to read \(path): \(error.localizedDescription)"]
        }

        // A multi-byte UTF-8 character may be split across the chunk
        // boundary; fall back to a lossy decode rather than failing outright.
        let text = String(data: chunk, encoding: .utf8) ?? String(decoding: chunk, as: UTF8.self)
        let allLines = splitLines(text)
        let truncatedByLines = allLines.count > maxLines
        let previewLines = truncatedByLines ? Array(allLines.prefix(maxLines)) : allLines

        var fileSize = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath) {
            fileSize = attrs[.size] as? Int ?? 0
        }
        let truncatedByBytes = fileSize > chunk.count

        return [
            "ok": true,
            "content": previewLines.joined(separator: "\n"),
            "truncated": truncatedByLines || truncatedByBytes,
        ]
    }

    /// args: { "path": String, "lines": Int? (default 10) }
    static func head(args: [String: Any]) -> [String: Any] {
        var previewArgs = args
        previewArgs["maxLines"] = args["lines"] as? Int ?? 10
        previewArgs["maxBytes"] = 1024 * 1024 // 1MB is plenty to find N lines in any normal text file
        let result = preview(args: previewArgs)
        guard result["ok"] as? Bool == true, let content = result["content"] as? String else {
            return result
        }
        return ["ok": true, "content": content, "truncated": result["truncated"] as? Bool ?? false]
    }

    /// args: { "path": String, "lines": Int? (default 20) }
    /// Seeks to a trailing window rather than loading the whole file — safe
    /// to call on multi-GB logs.
    static func tail(args: [String: Any]) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }
        let fullPath = expand(path)
        let wantLines = args["lines"] as? Int ?? 20
        let maxScanBytes: UInt64 = 2 * 1024 * 1024 // trailing window; plenty for a log tail

        guard let handle = FileHandle(forReadingAtPath: fullPath) else {
            return ["ok": false, "error": "Could not open file at \(path)"]
        }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd() else {
            return ["ok": false, "error": "Failed to read \(path)"]
        }
        let offset = fileSize > maxScanBytes ? fileSize - maxScanBytes : 0

        do {
            try handle.seek(toOffset: offset)
        } catch {
            return ["ok": false, "error": "Failed to seek: \(error.localizedDescription)"]
        }

        // Same Data?? flattening issue as preview() above — an empty file
        // (or a seek that lands exactly at EOF) must not be reported as a
        // read failure.
        let data: Data
        do {
            data = try handle.readToEnd() ?? Data()
        } catch {
            return ["ok": false, "error": "Failed to read \(path): \(error.localizedDescription)"]
        }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)

        var allLines = splitLines(text)
        if offset > 0 { allLines.removeFirst() } // drop the partial line at the window's start
        let lastLines = Array(allLines.suffix(wantLines))

        return [
            "ok": true,
            "content": lastLines.joined(separator: "\n"),
            "truncated": offset > 0,
        ]
    }

    /// args: { "path": String }
    /// Counts lines the way `wc -l` does, by streaming through the file in
    /// 1MB chunks rather than loading it all into memory — safe on
    /// multi-GB files that read()/preview() would choke on.
    static func countLines(args: [String: Any]) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }
        let fullPath = expand(path)

        guard let handle = FileHandle(forReadingAtPath: fullPath) else {
            return ["ok": false, "error": "Could not open file at \(path)"]
        }
        defer { try? handle.close() }

        let newline: UInt8 = 0x0A
        var newlineCount = 0
        var sawAnyBytes = false
        var endedWithNewline = false

        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            } catch {
                return ["ok": false, "error": "Failed to read \(path): \(error.localizedDescription)"]
            }
            if chunk.isEmpty { break }
            sawAnyBytes = true
            newlineCount += chunk.reduce(0) { $1 == newline ? $0 + 1 : $0 }
            endedWithNewline = chunk.last == newline
        }

        // A file with content but no trailing newline still has one more
        // (partial) line than the newline count alone reflects.
        let lineCount = (sawAnyBytes && !endedWithNewline) ? newlineCount + 1 : newlineCount

        return ["ok": true, "lines": lineCount]
    }

    /// args: { "path": String, "startLine": Int?, "endLine": Int?, "startByte": Int?, "endByte": Int? }
    /// Give either the line pair or the byte pair, not both. Lines are
    /// 1-indexed and inclusive, matching editor conventions.
    static func readRange(args: [String: Any]) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }
        let fullPath = expand(path)

        if let startByte = args["startByte"] as? Int, let endByte = args["endByte"] as? Int {
            guard startByte >= 0, endByte >= startByte else {
                return ["ok": false, "error": "'startByte'/'endByte' must satisfy 0 <= startByte <= endByte"]
            }
            guard let handle = FileHandle(forReadingAtPath: fullPath) else {
                return ["ok": false, "error": "Could not open file at \(path)"]
            }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: UInt64(startByte))
            } catch {
                return ["ok": false, "error": "Failed to seek: \(error.localizedDescription)"]
            }
            // Again: distinguish a genuine I/O error from a zero-byte read
            // at EOF (e.g. startByte == endByte, or startByte at file end).
            let data: Data
            do {
                data = try handle.read(upToCount: endByte - startByte) ?? Data()
            } catch {
                return ["ok": false, "error": "Failed to read \(path): \(error.localizedDescription)"]
            }
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            return ["ok": true, "content": text]
        }

        guard let startLine = args["startLine"] as? Int, let endLine = args["endLine"] as? Int else {
            return ["ok": false, "error": "Provide either 'startLine'/'endLine' or 'startByte'/'endByte'"]
        }
        guard startLine >= 1, endLine >= startLine else {
            return ["ok": false, "error": "'startLine'/'endLine' must satisfy 1 <= startLine <= endLine"]
        }

        guard let data = FileManager.default.contents(atPath: fullPath),
              let text = String(data: data, encoding: .utf8) else {
            return ["ok": false, "error": "Could not read file at \(path) as UTF-8 text"]
        }

        let allLines = splitLines(text)
        let lower = min(startLine, allLines.count + 1) - 1
        let upper = min(endLine, allLines.count)
        guard lower < upper else {
            return ["ok": true, "content": "", "totalLines": allLines.count]
        }

        return ["ok": true, "content": allLines[lower..<upper].joined(separator: "\n"), "totalLines": allLines.count]
    }

    // MARK: - Find & Replace

    /// args: { "path": String, "find": String, "replace": String? (default ""), "isRegex": Bool? (default false), "dryRun": Bool? (default false) }
    /// In-place find-and-replace across a text file's full contents.
    /// `isRegex: true` treats `find` as an NSRegularExpression pattern and
    /// `replace` as its template (supports $1-style backreferences).
    /// `dryRun: true` reports how many replacements would happen without
    /// touching the file — use it first on anything you can't easily undo.
    static func findReplace(args: [String: Any]) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }
        guard let find = args["find"] as? String, !find.isEmpty else {
            return ["ok": false, "error": "'find' is required"]
        }
        let replace = args["replace"] as? String ?? ""
        let isRegex = args["isRegex"] as? Bool ?? false
        let dryRun = args["dryRun"] as? Bool ?? false
        let fullPath = expand(path)

        guard let data = FileManager.default.contents(atPath: fullPath),
              let text = String(data: data, encoding: .utf8) else {
            return ["ok": false, "error": "Could not read \(path) as UTF-8 text"]
        }

        let newText: String
        let count: Int
        if isRegex {
            guard let regex = try? NSRegularExpression(pattern: find) else {
                return ["ok": false, "error": "'find' is not a valid regular expression"]
            }
            let fullRange = NSRange(text.startIndex..., in: text)
            count = regex.numberOfMatches(in: text, range: fullRange)
            newText = regex.stringByReplacingMatches(in: text, range: fullRange, withTemplate: replace)
        } else {
            count = text.components(separatedBy: find).count - 1
            newText = text.replacingOccurrences(of: find, with: replace)
        }

        if dryRun || count == 0 {
            return ["ok": true, "replacements": count, "dryRun": dryRun]
        }

        do {
            try newText.write(toFile: fullPath, atomically: true, encoding: .utf8)
            return ["ok": true, "replacements": count, "dryRun": false, "path": fullPath]
        } catch {
            return ["ok": false, "error": "Failed to write \(path): \(error.localizedDescription)"]
        }
    }

    // MARK: - Hashing & Verification

    /// args: { "path": String, "algorithm": String? ("sha256" | "sha512" | "md5", default "sha256") }
    static func hash(args: [String: Any]) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }
        let fullPath = expand(path)
        let algorithm = (args["algorithm"] as? String ?? "sha256").lowercased()

        guard let data = FileManager.default.contents(atPath: fullPath) else {
            return ["ok": false, "error": "Could not read file at \(path)"]
        }

        let digest: String
        switch algorithm {
        case "sha256":
            digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "sha512":
            digest = SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "md5":
            digest = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        default:
            return ["ok": false, "error": "'algorithm' must be one of: sha256, sha512, md5"]
        }

        return ["ok": true, "algorithm": algorithm, "hash": digest]
    }

    /// args: { "path": String, "expected": String, "algorithm": String? (default "sha256") }
    static func verifyChecksum(args: [String: Any]) -> [String: Any] {
        guard let expected = args["expected"] as? String, !expected.isEmpty else {
            return ["ok": false, "error": "'expected' is required"]
        }
        let result = hash(args: args)
        guard result["ok"] as? Bool == true, let actual = result["hash"] as? String else {
            return result
        }
        return [
            "ok": true,
            "matches": actual.caseInsensitiveCompare(expected) == .orderedSame,
            "expected": expected,
            "actual": actual,
        ]
    }

    // MARK: - Diff

    /// args: { "pathA": String, "pathB": String, "maxLines": Int? (default 2000) }
    /// Line-based diff via classic LCS backtrace. `maxLines` guards against
    /// the O(n*m) table blowing up memory on huge files — raise it explicitly
    /// if you really need to diff something bigger.
    static func diff(args: [String: Any]) -> [String: Any] {
        guard let pathA = args["pathA"] as? String, !pathA.isEmpty else {
            return ["ok": false, "error": "'pathA' is required"]
        }
        guard let pathB = args["pathB"] as? String, !pathB.isEmpty else {
            return ["ok": false, "error": "'pathB' is required"]
        }
        let maxLines = args["maxLines"] as? Int ?? 2000

        guard let dataA = FileManager.default.contents(atPath: expand(pathA)),
              let textA = String(data: dataA, encoding: .utf8) else {
            return ["ok": false, "error": "Could not read \(pathA) as UTF-8 text"]
        }
        guard let dataB = FileManager.default.contents(atPath: expand(pathB)),
              let textB = String(data: dataB, encoding: .utf8) else {
            return ["ok": false, "error": "Could not read \(pathB) as UTF-8 text"]
        }

        let linesA = splitLines(textA)
        let linesB = splitLines(textB)

        guard linesA.count <= maxLines, linesB.count <= maxLines else {
            return ["ok": false, "error": "File exceeds \(maxLines) lines — pass a higher 'maxLines' or narrow the range with readRange() first"]
        }

        let result = lineDiff(linesA, linesB)
        return ["ok": true, "added": result.added, "removed": result.removed, "changed": result.changed]
    }

    /// LCS-based line diff. A removal immediately followed by an addition —
    /// within the same contiguous edit run — is folded into a "changed"
    /// pair rather than reported as two separate ops.
    ///
    /// FIX: this previously paired the Nth removed line with the Nth added
    /// line *globally* across the whole file (removedLines[k] <->
    /// addedLines[k] for every k), instead of only within a single
    /// contiguous run of edits. That meant two completely unrelated edits —
    /// e.g. a removal on line 3 and an unconnected addition on line 400 —
    /// could get reported as one "changed" pair simply because they were
    /// both the first removal/addition found, which misrepresents the diff.
    /// Runs are now flushed (and paired only within themselves) as soon as
    /// a match is hit, matching the "immediately followed by" language in
    /// the doc comment above.
    private static func lineDiff(_ a: [String], _ b: [String]) -> (added: [[String: Any]], removed: [[String: Any]], changed: [[String: Any]]) {
        let n = a.count, m = b.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        var added: [[String: Any]] = []
        var removed: [[String: Any]] = []
        var changed: [[String: Any]] = []

        // Lines accumulated for the current contiguous run of edits (no
        // match has interrupted them yet).
        var runRemoved: [[String: Any]] = []
        var runAdded: [[String: Any]] = []

        func flushRun() {
            guard !runRemoved.isEmpty || !runAdded.isEmpty else { return }
            let pairCount = min(runRemoved.count, runAdded.count)
            for k in 0..<pairCount {
                changed.append([
                    "oldLine": runRemoved[k]["line"] as Any,
                    "oldText": runRemoved[k]["text"] as Any,
                    "newLine": runAdded[k]["line"] as Any,
                    "newText": runAdded[k]["text"] as Any,
                ])
            }
            removed.append(contentsOf: runRemoved[pairCount...])
            added.append(contentsOf: runAdded[pairCount...])
            runRemoved.removeAll()
            runAdded.removeAll()
        }

        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                flushRun()
                i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                runRemoved.append(["line": i + 1, "text": a[i]])
                i += 1
            } else {
                runAdded.append(["line": j + 1, "text": b[j]])
                j += 1
            }
        }
        while i < n { runRemoved.append(["line": i + 1, "text": a[i]]); i += 1 }
        while j < m { runAdded.append(["line": j + 1, "text": b[j]]); j += 1 }
        flushRun()

        return (added, removed, changed)
    }

    // MARK: - Directory Insights

    /// args: { "path": String, "maxDepth": Int? (default 3), "maxItems": Int? (default 500) }
    /// Renders an indented hierarchy string, like the `tree` CLI tool.
    static func tree(args: [String: Any]) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }
        let fullPath = expand(path)
        let maxDepth = args["maxDepth"] as? Int ?? 3
        let maxItems = args["maxItems"] as? Int ?? 500
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else {
            return ["ok": false, "error": "\(path) is not a directory"]
        }

        var lines: [String] = [(fullPath as NSString).lastPathComponent + "/"]
        var count = 1
        var truncated = false

        func walk(_ dirPath: String, prefix: String, depth: Int) {
            guard depth <= maxDepth, !truncated else { return }
            let entries = (try? fm.contentsOfDirectory(atPath: dirPath))?.sorted() ?? []
            for (index, entry) in entries.enumerated() {
                if count >= maxItems { truncated = true; return }
                let entryPath = (dirPath as NSString).appendingPathComponent(entry)
                var entryIsDir: ObjCBool = false
                fm.fileExists(atPath: entryPath, isDirectory: &entryIsDir)
                let isLast = index == entries.count - 1
                lines.append(prefix + (isLast ? "└── " : "├── ") + entry + (entryIsDir.boolValue ? "/" : ""))
                count += 1
                if entryIsDir.boolValue {
                    walk(entryPath, prefix: prefix + (isLast ? "    " : "│   "), depth: depth + 1)
                }
            }
        }

        walk(fullPath, prefix: "", depth: 1)

        var response: [String: Any] = ["ok": true, "tree": lines.joined(separator: "\n")]
        if truncated { response["truncated"] = true }
        return response
    }

    /// args: { "path": String, "recursive": Bool? (default true), "maxDepth": Int? (default 5), "maxItems": Int? (default 2000) }
    static func summarizeFolder(args: [String: Any]) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }

        let listArgs: [String: Any] = [
            "path": path,
            "recursive": args["recursive"] as? Bool ?? true,
            "maxDepth": args["maxDepth"] as? Int ?? 5,
            "maxItems": args["maxItems"] as? Int ?? 2000,
        ]
        let listResult = list(args: listArgs)
        guard listResult["ok"] as? Bool == true, let items = listResult["items"] as? [[String: Any]] else {
            return listResult
        }

        let files = items.filter { ($0["isDirectory"] as? Bool) == false }
        let totalSize = files.reduce(0) { $0 + (($1["size"] as? Int) ?? 0) }

        var extensionCounts: [String: Int] = [:]
        for file in files {
            let ext = (file["extension"] as? String)?.lowercased() ?? ""
            if !ext.isEmpty { extensionCounts[ext, default: 0] += 1 }
        }

        let biggest = files.sorted { (($0["size"] as? Int) ?? 0) > (($1["size"] as? Int) ?? 0) }.prefix(10)
        let byModified = files.sorted { (($0["modified"] as? Double) ?? 0) < (($1["modified"] as? Double) ?? 0) }
        let dupResult = group(args: ["path": path, "by": "duplicates", "recursive": args["recursive"] as? Bool ?? true])

        var response: [String: Any] = [
            "ok": true,
            "totalFiles": files.count,
            "totalSize": totalSize,
            "extensionCounts": extensionCounts,
            "biggestFiles": Array(biggest),
            "duplicateSetCount": dupResult["duplicateSetCount"] as? Int ?? 0,
        ]
        if let oldest = byModified.first { response["oldest"] = oldest }
        if let newest = byModified.last { response["newest"] = newest }
        if listResult["truncated"] != nil { response["truncated"] = true }
        return response
    }

    /// args: { "path": String, "count": Int? (default 20), "recursive": Bool? (default true), "maxDepth": Int? (default 5), "maxItems": Int? (default 2000) }
    static func recentFiles(args: [String: Any]) -> [String: Any] {
        topFiles(args: args, sortKey: "modified", ascending: false)
    }

    /// args: same shape as recentFiles()
    static func largestFiles(args: [String: Any]) -> [String: Any] {
        topFiles(args: args, sortKey: "size", ascending: false)
    }

    private static func topFiles(args: [String: Any], sortKey: String, ascending: Bool) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }
        let count = args["count"] as? Int ?? 20

        let listResult = list(args: [
            "path": path,
            "recursive": args["recursive"] as? Bool ?? true,
            "maxDepth": args["maxDepth"] as? Int ?? 5,
            "maxItems": args["maxItems"] as? Int ?? 2000,
        ])
        guard listResult["ok"] as? Bool == true, let items = listResult["items"] as? [[String: Any]] else {
            return listResult
        }

        let files = items.filter { ($0["isDirectory"] as? Bool) == false }
        let sorted = files.sorted { lhs, rhs in
            let a = (lhs[sortKey] as? Double) ?? Double((lhs[sortKey] as? Int) ?? 0)
            let b = (rhs[sortKey] as? Double) ?? Double((rhs[sortKey] as? Int) ?? 0)
            return ascending ? a < b : a > b
        }

        var response: [String: Any] = ["ok": true, "files": Array(sorted.prefix(count))]
        if listResult["truncated"] != nil { response["truncated"] = true }
        return response
    }

    /// args: { "path": String, "recursive": Bool? (default true), "maxDepth": Int? (default 5), "maxItems": Int? (default 2000) }
    static func emptyFiles(args: [String: Any]) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }
        let listResult = list(args: [
            "path": path,
            "recursive": args["recursive"] as? Bool ?? true,
            "maxDepth": args["maxDepth"] as? Int ?? 5,
            "maxItems": args["maxItems"] as? Int ?? 2000,
        ])
        guard listResult["ok"] as? Bool == true, let items = listResult["items"] as? [[String: Any]] else {
            return listResult
        }
        let empties = items.filter { ($0["isDirectory"] as? Bool) == false && (($0["size"] as? Int) ?? -1) == 0 }
        return ["ok": true, "files": empties, "count": empties.count]
    }

    /// args: same shape as emptyFiles()
    static func emptyDirectories(args: [String: Any]) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }
        let listResult = list(args: [
            "path": path,
            "recursive": args["recursive"] as? Bool ?? true,
            "maxDepth": args["maxDepth"] as? Int ?? 5,
            "maxItems": args["maxItems"] as? Int ?? 2000,
        ])
        guard listResult["ok"] as? Bool == true, let items = listResult["items"] as? [[String: Any]] else {
            return listResult
        }
        let fm = FileManager.default
        let empties = items.filter { $0["isDirectory"] as? Bool == true }.filter { dir in
            guard let dirPath = dir["path"] as? String else { return false }
            return ((try? fm.contentsOfDirectory(atPath: dirPath)) ?? ["_"]).isEmpty
        }
        return ["ok": true, "directories": empties, "count": empties.count]
    }

    /// args: { "path": String, "recursive": Bool? (default true), "maxDepth": Int? (default 5), "maxItems": Int? (default 2000) }
    /// Finds symlinks whose target no longer resolves.
    static func brokenSymlinks(args: [String: Any]) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }
        let listResult = list(args: [
            "path": path,
            "recursive": args["recursive"] as? Bool ?? true,
            "maxDepth": args["maxDepth"] as? Int ?? 5,
            "maxItems": args["maxItems"] as? Int ?? 2000,
        ])
        guard listResult["ok"] as? Bool == true, let items = listResult["items"] as? [[String: Any]] else {
            return listResult
        }

        let fm = FileManager.default
        let broken = items.compactMap { item -> [String: Any]? in
            guard item["isSymlink"] as? Bool == true, let itemPath = item["path"] as? String,
                  !fm.fileExists(atPath: itemPath) else { return nil }
            return ["path": itemPath, "target": item["symlinkTarget"] as? String ?? "?"]
        }

        var response: [String: Any] = ["ok": true, "brokenSymlinks": broken, "count": broken.count]
        if listResult["truncated"] != nil { response["truncated"] = true }
        return response
    }

    // MARK: - Fuzzy Search

    /// args: { "path": String, "query": String, "recursive": Bool? (default true), "maxDepth": Int? (default 5), "maxItems": Int? (default 2000), "maxResults": Int? (default 20) }
    /// Ranks filenames by edit distance to `query` instead of requiring an
    /// exact substring — finds "reprot.docx" when asked for "report".
    static func fuzzySearch(args: [String: Any]) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }
        guard let query = args["query"] as? String, !query.isEmpty else {
            return ["ok": false, "error": "'query' is required"]
        }
        let maxResults = args["maxResults"] as? Int ?? 20

        let listResult = list(args: [
            "path": path,
            "recursive": args["recursive"] as? Bool ?? true,
            "maxDepth": args["maxDepth"] as? Int ?? 5,
            "maxItems": args["maxItems"] as? Int ?? 2000,
        ])
        guard listResult["ok"] as? Bool == true, let items = listResult["items"] as? [[String: Any]] else {
            return listResult
        }

        let lowerQuery = query.lowercased()
        let scored: [(item: [String: Any], distance: Int)] = items.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            let stem = (name as NSString).deletingPathExtension.lowercased()
            return (item, levenshtein(lowerQuery, stem))
        }
        let ranked = scored.sorted { $0.distance < $1.distance }.prefix(maxResults)
        let matches = ranked.map { pair -> [String: Any] in
            var entry = pair.item
            entry["distance"] = pair.distance
            return entry
        }

        return ["ok": true, "matches": matches, "count": matches.count]
    }

    /// Classic iterative Levenshtein edit distance.
    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a), bChars = Array(b)
        let n = aChars.count, m = bChars.count
        if n == 0 { return m }
        if m == 0 { return n }

        var previous = Array(0...m)
        var current = Array(repeating: 0, count: m + 1)

        for i in 1...n {
            current[0] = i
            for j in 1...m {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[m]
    }

    // MARK: - Safe Delete (Trash)

    private static var trashRoot: String { expand("~/.MacBridgeTrash") }

    /// args: { "path": String }
    /// Moves the item into ~/.MacBridgeTrash/ instead of deleting it
    /// outright. Name collisions get a numeric suffix rather than an
    /// overwrite — trash is a safety net, not another place to lose data.
    static func moveToTrash(args: [String: Any]) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }
        let fullPath = expand(path)
        let fm = FileManager.default

        guard fm.fileExists(atPath: fullPath) else {
            return ["ok": false, "error": "No file or folder exists at \(path)"]
        }

        if !fm.fileExists(atPath: trashRoot) {
            try? fm.createDirectory(atPath: trashRoot, withIntermediateDirectories: true)
        }

        let name = (fullPath as NSString).lastPathComponent
        var destination = (trashRoot as NSString).appendingPathComponent(name)
        var suffix = 1
        while fm.fileExists(atPath: destination) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            let candidate = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            destination = (trashRoot as NSString).appendingPathComponent(candidate)
            suffix += 1
        }

        do {
            try fm.moveItem(atPath: fullPath, toPath: destination)
            return ["ok": true, "originalPath": fullPath, "trashPath": destination]
        } catch {
            return ["ok": false, "error": "Failed to move to trash: \(error.localizedDescription)"]
        }
    }

    /// args: {} — lists items currently sitting in ~/.MacBridgeTrash/.
    static func listTrash(args: [String: Any]) -> [String: Any] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: trashRoot) else {
            return ["ok": true, "items": []]
        }
        let names = (try? fm.contentsOfDirectory(atPath: trashRoot)) ?? []
        let items = names.compactMap { name in
            metadata(atPath: (trashRoot as NSString).appendingPathComponent(name), name: name)
        }
        return ["ok": true, "items": items]
    }

    /// args: { "name": String, "restoreTo": String? }
    /// Trash doesn't track original locations, so pass `restoreTo`
    /// explicitly when it matters — defaults to the home directory.
    static func restoreFromTrash(args: [String: Any]) -> [String: Any] {
        guard let name = args["name"] as? String, !name.isEmpty else {
            return ["ok": false, "error": "'name' is required — see listTrash() for available items"]
        }
        let source = (trashRoot as NSString).appendingPathComponent(name)
        let fm = FileManager.default
        guard fm.fileExists(atPath: source) else {
            return ["ok": false, "error": "No item named \(name) in trash"]
        }

        let destination = (args["restoreTo"] as? String).map(expand) ?? expand("~/\(name)")
        if fm.fileExists(atPath: destination) {
            return ["ok": false, "error": "Something already exists at \(destination) — pass a different 'restoreTo'"]
        }

        do {
            try fm.moveItem(atPath: source, toPath: destination)
            return ["ok": true, "path": destination]
        } catch {
            return ["ok": false, "error": "Failed to restore: \(error.localizedDescription)"]
        }
    }

    // MARK: - Permissions

    /// args: { "path": String, "mode": String } — octal string, e.g. "755" or "644".
    static func chmod(args: [String: Any]) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }
        guard let mode = args["mode"] as? String, let value = Int(mode, radix: 8) else {
            return ["ok": false, "error": "'mode' is required and must be an octal string, e.g. \"755\""]
        }
        let fullPath = expand(path)

        do {
            try FileManager.default.setAttributes([.posixPermissions: value], ofItemAtPath: fullPath)
            return ["ok": true, "path": fullPath, "mode": mode]
        } catch {
            return ["ok": false, "error": "Failed to chmod: \(error.localizedDescription)"]
        }
    }

    /// args: { "path": String }
    static func permissionsInfo(args: [String: Any]) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }
        let fullPath = expand(path)

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath) else {
            return ["ok": false, "error": "Could not stat \(path)"]
        }

        let posix = attrs[.posixPermissions] as? Int ?? 0
        let fm = FileManager.default

        return [
            "ok": true,
            "mode": String(posix, radix: 8),
            "owner": attrs[.ownerAccountName] as? String ?? "unknown",
            "group": attrs[.groupOwnerAccountName] as? String ?? "unknown",
            "readable": fm.isReadableFile(atPath: fullPath),
            "writable": fm.isWritableFile(atPath: fullPath),
            "executable": fm.isExecutableFile(atPath: fullPath),
        ]
    }

    // MARK: - Lock / Unlock

    /// args: { "path": String } — sets the filesystem "user immutable" flag
    /// (equivalent to `chflags uchg`), blocking accidental edits or deletes
    /// until unlock() is called. This is an OS-level flag, not app-level, so
    /// it holds even against tools outside MacBridge.
    static func lock(args: [String: Any]) -> [String: Any] {
        setImmutable(args: args, locked: true)
    }

    /// args: { "path": String }
    static func unlock(args: [String: Any]) -> [String: Any] {
        setImmutable(args: args, locked: false)
    }

    private static func setImmutable(args: [String: Any], locked: Bool) -> [String: Any] {
        guard let path = requirePath(args) else {
            return ["ok": false, "error": "'path' is required"]
        }
        let fullPath = expand(path)
        do {
            try FileManager.default.setAttributes([.immutable: locked], ofItemAtPath: fullPath)
            return ["ok": true, "path": fullPath, "locked": locked]
        } catch {
            return ["ok": false, "error": "Failed to \(locked ? "lock" : "unlock"): \(error.localizedDescription)"]
        }
    }

    // MARK: - Batch Operations

    /// args: { "operations": [{ "from": String, "to": String, "overwrite": Bool? }] }
    /// Runs move() per entry and keeps going past individual failures — check
    /// each result's "ok" rather than the top-level one.
    static func batchMove(args: [String: Any]) -> [String: Any] {
        runBatch(args: args) { move(args: $0) }
    }

    /// args: same shape as batchMove()
    static func batchCopy(args: [String: Any]) -> [String: Any] {
        runBatch(args: args) { copy(args: $0) }
    }

    /// args: { "operations": [{ "from": String, "to": String, "overwrite": Bool? }] }
    /// Rename is move() under the hood (see move() above), so this is an
    /// alias — kept separate for callers that think in "rename" terms.
    static func batchRename(args: [String: Any]) -> [String: Any] {
        batchMove(args: args)
    }

    /// args: { "paths": [String], "recursive": Bool? (default true) }
    static func batchDelete(args: [String: Any]) -> [String: Any] {
        guard let paths = args["paths"] as? [String] else {
            return ["ok": false, "error": "'paths' must be an array of strings"]
        }
        let recursive = args["recursive"] as? Bool ?? true
        var results: [[String: Any]] = []
        var failureCount = 0
        for path in paths {
            let result = delete(args: ["path": path, "recursive": recursive])
            if result["ok"] as? Bool != true { failureCount += 1 }
            results.append(result)
        }
        return ["ok": true, "results": results, "successCount": results.count - failureCount, "failureCount": failureCount]
    }

    private static func runBatch(args: [String: Any], operation: ([String: Any]) -> [String: Any]) -> [String: Any] {
        guard let operations = args["operations"] as? [[String: Any]] else {
            return ["ok": false, "error": "'operations' must be an array of { from, to } objects"]
        }
        var results: [[String: Any]] = []
        var failureCount = 0
        for op in operations {
            let result = operation(op)
            if result["ok"] as? Bool != true { failureCount += 1 }
            results.append(result)
        }
        return ["ok": true, "results": results, "successCount": results.count - failureCount, "failureCount": failureCount]
    }

    // MARK: - Compression

    /// args: { "source": String, "destination": String, "overwrite": Bool? (default false) }
    /// Zips a file or folder using `ditto` — the same mechanism behind
    /// Finder's "Compress" — which preserves metadata/resource forks better
    /// than a raw `zip` invocation would.
    static func zip(args: [String: Any]) -> [String: Any] {
        guard let source = args["source"] as? String, !source.isEmpty else {
            return ["ok": false, "error": "'source' is required"]
        }
        guard let destination = args["destination"] as? String, !destination.isEmpty else {
            return ["ok": false, "error": "'destination' is required"]
        }
        let fullSource = expand(source)
        let fullDestination = expand(destination)
        let overwrite = args["overwrite"] as? Bool ?? false
        let fm = FileManager.default

        guard fm.fileExists(atPath: fullSource) else {
            return ["ok": false, "error": "No file or folder exists at \(source)"]
        }
        if fm.fileExists(atPath: fullDestination) {
            if !overwrite {
                return ["ok": false, "error": "Something already exists at \(destination) — pass overwrite: true to replace it"]
            }
            try? fm.removeItem(atPath: fullDestination)
        }

        let destDir = (fullDestination as NSString).deletingLastPathComponent
        if !destDir.isEmpty && !fm.fileExists(atPath: destDir) {
            try? fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        }

        return runDitto(arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", fullSource, fullDestination],
                         resultPath: fullDestination)
    }

    /// args: { "source": String, "destination": String, "overwrite": Bool? (default false) }
    /// Unzips (or expands any ditto-compatible archive) into `destination`,
    /// creating it as a directory if needed.
    static func unzip(args: [String: Any]) -> [String: Any] {
        guard let source = args["source"] as? String, !source.isEmpty else {
            return ["ok": false, "error": "'source' is required"]
        }
        guard let destination = args["destination"] as? String, !destination.isEmpty else {
            return ["ok": false, "error": "'destination' is required"]
        }
        let fullSource = expand(source)
        let fullDestination = expand(destination)
        let overwrite = args["overwrite"] as? Bool ?? false
        let fm = FileManager.default

        guard fm.fileExists(atPath: fullSource) else {
            return ["ok": false, "error": "No file exists at \(source)"]
        }
        if fm.fileExists(atPath: fullDestination) {
            if !overwrite {
                return ["ok": false, "error": "Something already exists at \(destination) — pass overwrite: true to replace it"]
            }
            try? fm.removeItem(atPath: fullDestination)
        }

        do {
            try fm.createDirectory(atPath: fullDestination, withIntermediateDirectories: true)
        } catch {
            return ["ok": false, "error": "Failed to create destination directory: \(error.localizedDescription)"]
        }

        return runDitto(arguments: ["-x", "-k", fullSource, fullDestination], resultPath: fullDestination)
    }

    /// Shells out to /usr/bin/ditto and normalizes its result into the
    /// module's usual { ok, path } / { ok: false, error } shape.
    private static func runDitto(arguments: [String], resultPath: String) -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return ["ok": false, "error": "Failed to run ditto: \(error.localizedDescription)"]
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8) ?? "Unknown ditto error"
            return ["ok": false, "error": "ditto failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))"]
        }

        return ["ok": true, "path": resultPath]
    }

    // MARK: - Not implemented here (by design)
    //
    // These wishlist items didn't fit a mechanical "add a function" pass —
    // each needs a real design decision first, not just more code:
    //
    //   openWith(), revealInFinder(), mountDiskImage()
    //     GUI/Finder operations. Per the header comment at the top of this
    //     file, that's Finder.swift's job, not raw FileManager's.
    //
    //   gitStatus(), gitDiff(), gitHistory(), currentBranch()
    //     Doable by shelling out to `git` via Process, but probably deserves
    //     its own Git.swift module rather than living inside file ops.
    //
    //   detectProject(), projectSummary()
    //     Needs a maintained table of "marker file → stack" (Package.swift,
    //     package.json, Cargo.toml, ...) — a small module of its own.
    //
    //   semanticSearch(), similarFiles(), relatedFiles(), buildFileGraph()
    //     Need an embeddings model or an external index; Foundation doesn't
    //     give you this for free. Worth scoping as its own piece of work.
    //
    //   beginTransaction()/rollback()/commit(), undoLastOperation()/redo()
    //     Need a real operation journal + snapshot store to be trustworthy.
    //     A half-implemented "undo" is worse than none.
    //
    //   watchDirectory(), streamFile()
    //     Need DispatchSource/FSEvents and a stateful subscription, which
    //     doesn't fit this file's "stateless static function" shape.
    //
    //   snapshotDirectory()/compareSnapshots()
    //     Really "index + diff", reusing tree()/diff() above. zip()/unzip()
    //     (previously listed here too) are now implemented above.
}