// MacBridge/Sources/MacBridge/Modules/Reminders.swift
// Owns: EventKit (reminders only — see Calendar.swift for calendar events).
// Exposes static functions returning JSON-safe [String: Any] dictionaries.
// Knows nothing about HTTP — Router.swift is the only caller.

import Foundation
import EventKit

enum Reminders {

    private static let store = EKEventStore()

    static func requestAccess(completion: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            store.requestFullAccessToReminders(completion: { granted, _ in completion(granted) })
        } else {
            store.requestAccess(to: .reminder, completion: { granted, _ in completion(granted) })
        }
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let str = value as? String else { return nil }
        let strict = ISO8601DateFormatter()
        if let date = strict.date(from: str) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: str)
    }

    private static func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// args: { "includeCompleted": Bool? (default false) }
    static func list(args: [String: Any]) -> [String: Any] {
        let includeCompleted = args["includeCompleted"] as? Bool ?? false
        let predicate = store.predicateForReminders(in: nil)

        // EKEventStore's reminder fetch is async-callback based; bridge it
        // synchronously since each request already runs on its own
        // background queue (Server.swift's acceptLoop).
        let semaphore = DispatchSemaphore(value: 0)
        var result: [[String: Any]] = []

        store.fetchReminders(matching: predicate) { reminders in
            for reminder in reminders ?? [] {
                if !includeCompleted && reminder.isCompleted { continue }
                result.append([
                    "id": reminder.calendarItemIdentifier,
                    "title": reminder.title ?? "",
                    "notes": reminder.notes ?? "",
                    "completed": reminder.isCompleted,
                    "dueDate": reminder.dueDateComponents
                        .flatMap { Foundation.Calendar.current.date(from: $0) }
                        .map { isoString($0) } ?? NSNull()
                ])
            }
            semaphore.signal()
        }

        semaphore.wait()
        return ["ok": true, "reminders": result]
    }

    /// args: { "title": String, "notes": String?, "dueDate": ISO8601 string? }
    static func create(args: [String: Any]) -> [String: Any] {
        guard let title = args["title"] as? String, !title.isEmpty else {
            return ["ok": false, "error": "'title' is required"]
        }
        guard let calendar = store.defaultCalendarForNewReminders() else {
            return ["ok": false, "error": "No default reminders list available — check Reminders permission"]
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = args["notes"] as? String
        reminder.calendar = calendar

        if let due = parseDate(args["dueDate"]) {
            reminder.dueDateComponents = Foundation.Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: due
            )
        }

        do {
            try store.save(reminder, commit: true)
            return ["ok": true, "id": reminder.calendarItemIdentifier]
        } catch {
            return ["ok": false, "error": "Failed to save reminder: \(error.localizedDescription)"]
        }
    }

    /// args: { "id": String }  — the reminder's calendarItemIdentifier
    static func complete(args: [String: Any]) -> [String: Any] {
        guard let id = args["id"] as? String, !id.isEmpty else {
            return ["ok": false, "error": "'id' is required"]
        }
        guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else {
            return ["ok": false, "error": "No reminder found with id \(id)"]
        }

        item.isCompleted = true

        do {
            try store.save(item, commit: true)
            return ["ok": true, "id": id]
        } catch {
            return ["ok": false, "error": "Failed to update reminder: \(error.localizedDescription)"]
        }
    }
}
