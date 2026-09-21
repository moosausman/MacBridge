// MacBridge/Sources/MacBridge/Router.swift
// Maps HTTP paths to module functions. No macOS framework imports here —
// every framework call lives in Modules/*.swift. This file should never
// grow business logic; if a route needs more than a one-line call into a
// module, that logic belongs in the module, not here.
//
// Contract: Router.dispatch(path:args:) -> [String: Any]
// `args` is the "args" object from the POST body's JSON, e.g.:
//   { "args": { "title": "Dentist", "start": "2026-07-01T10:00:00Z" } }
//
// Every module response includes an "ok": Bool. On failure, an "error"
// String is included.

import Foundation

enum Router {

    static func dispatch(path: String, args: [String: Any]) -> [String: Any] {
        if let result = PowerRouter.dispatch(path: path, args: args) { return result }
        switch path {

        // Calendar
        case "/calendar/list":
            return Calendar_.list(args: args)
        case "/calendar/create":
            return Calendar_.create(args: args)
        case "/calendar/delete":
            return Calendar_.delete(args: args)
        case "/calendar/calendars":
            return Calendar_.calendars(args: args)

        // Reminders
        case "/reminders/list":
            return Reminders.list(args: args)
        case "/reminders/create":
            return Reminders.create(args: args)
        case "/reminders/complete":
            return Reminders.complete(args: args)

        // Contacts
        case "/contacts/search":
            return ContactsModule.search(args: args)
        case "/contacts/list":
            return ContactsModule.list(args: args)

        // Notifications
        case "/notifications/send":
            return Notifications.send(args: args)

        // Clipboard
        case "/clipboard/get":
            return Clipboard.get(args: args)
        case "/clipboard/set":
            return Clipboard.set(args: args)

        // Finder
        case "/finder/open":
            return Finder.open(args: args)
        case "/finder/reveal":
            return Finder.reveal(args: args)

        // AppleScript (arbitrary script execution — see file header for
        // the localhost-only caveat)
        case "/applescript/run":
            return AppleScriptModule.run(args: args)

        // Files (raw filesystem access via FileManager)
        case "/files/read":
            return Files.read(args: args)
        case "/files/write":
            return Files.write(args: args)
        case "/files/append":
            return Files.append(args: args)
        case "/files/touch":
            return Files.touch(args: args)
        case "/files/list":
            return Files.list(args: args)
        case "/files/delete":
            return Files.delete(args: args)
        case "/files/mkdir":
            return Files.mkdir(args: args)
        case "/files/move":
            return Files.move(args: args)
        case "/files/copy":
            return Files.copy(args: args)
        case "/files/duplicate":
            return Files.duplicate(args: args)
        case "/files/exists":
            return Files.exists(args: args)
        case "/files/info":
            return Files.info(args: args)
        case "/files/group":
            return Files.group(args: args)
        case "/files/search":
            return Files.search(args: args)

        // Files — partial / windowed reads
        case "/files/preview":
            return Files.preview(args: args)
        case "/files/head":
            return Files.head(args: args)
        case "/files/tail":
            return Files.tail(args: args)
        case "/files/count-lines":
            return Files.countLines(args: args)
        case "/files/read-range":
            return Files.readRange(args: args)

        // Files — hashing / diffing
        case "/files/hash":
            return Files.hash(args: args)
        case "/files/verify-checksum":
            return Files.verifyChecksum(args: args)
        case "/files/diff":
            return Files.diff(args: args)
        case "/files/find-replace":
            return Files.findReplace(args: args)

        // Files — directory analysis
        case "/files/tree":
            return Files.tree(args: args)
        case "/files/summarize-folder":
            return Files.summarizeFolder(args: args)
        case "/files/recent":
            return Files.recentFiles(args: args)
        case "/files/largest":
            return Files.largestFiles(args: args)
        case "/files/empty-files":
            return Files.emptyFiles(args: args)
        case "/files/empty-directories":
            return Files.emptyDirectories(args: args)
        case "/files/broken-symlinks":
            return Files.brokenSymlinks(args: args)
        case "/files/fuzzy-search":
            return Files.fuzzySearch(args: args)

        // Files — trash
        case "/files/trash":
            return Files.moveToTrash(args: args)
        case "/files/trash/list":
            return Files.listTrash(args: args)
        case "/files/trash/restore":
            return Files.restoreFromTrash(args: args)

        // Files — permissions / immutability
        case "/files/chmod":
            return Files.chmod(args: args)
        case "/files/permissions":
            return Files.permissionsInfo(args: args)
        case "/files/lock":
            return Files.lock(args: args)
        case "/files/unlock":
            return Files.unlock(args: args)

        // Files — compression
        case "/files/zip":
            return Files.zip(args: args)
        case "/files/unzip":
            return Files.unzip(args: args)

        // Files — batch operations
        case "/files/batch/move":
            return Files.batchMove(args: args)
        case "/files/batch/copy":
            return Files.batchCopy(args: args)
        case "/files/batch/rename":
            return Files.batchRename(args: args)
        case "/files/batch/delete":
            return Files.batchDelete(args: args)

        // Mail
        case "/mail/list":
            return Mail.list(args: args)
        case "/mail/search":
            return Mail.search(args: args)
        case "/mail/send":
            return Mail.send(args: args)

        // Safari
        case "/safari/open":
            return Safari.openURL(args: args)
        case "/safari/tabs":
            return Safari.listTabs(args: args)
        case "/safari/current-tab":
            return Safari.currentTab(args: args)
        case "/safari/page-text":
            return Safari.pageText(args: args)

        // Spotify
        case "/spotify/state": return SpotifyModule.state(args: args)
        case "/spotify/play-uri": return SpotifyModule.playURI(args: args)
        case "/spotify/control": return SpotifyModule.control(args: args)

        // Shortcuts (arbitrary shortcut execution — see file header for
        // the localhost-only caveat)
        case "/shortcuts/run":
            return ShortcutsModule.run(args: args)

        // System
        case "/system/volume/get":
            return System.getVolume(args: args)
        case "/system/volume/set":
            return System.setVolume(args: args)
        case "/system/battery":
            return System.battery(args: args)
        case "/system/sleep":
            return System.sleep(args: args)
        case "/system/lock":
            return System.lock(args: args)
        
        // Shell
        case "/shell/stage": return Shell.stage(args: args)
        case "/shell/stageScript": return Shell.stageScript(args: args)
        case "/shell/readFrontWindow": return Shell.readFrontWindow(args: args)
        case "/shell/run": return Shell.run(args: args)
        case "/shell/runScript": return Shell.runScript(args: args)
        case "/shell/spawn": return Shell.spawn(args: args)
        case "/shell/status": return Shell.jobStatus(args: args)
        case "/shell/kill": return Shell.jobKill(args: args)
        case "/shell/jobs": return Shell.jobList(args: args)

        // KeyStrokes

        case "/keyboard/type": return Keyboard.typeText(args: args)
        case "/keyboard/press": return Keyboard.pressKey(args: args)
        case "/keyboard/sequence": return Keyboard.runSequence(args: args)
        case "/keyboard/activate": return Keyboard.activateApp(args: args)
        case "/keyboard/frontmost": return Keyboard.frontmostApp(args: args)
        case "/keyboard/checkAccessibility": return Keyboard.checkAccessibility(args: args)

        default:
            return ["ok": false, "error": "Unknown route: \(path)"]
        }
    }
}