// MacBridge/Sources/MacBridge/Modules/Calendar.swift
// Owns: EventKit (calendar events only — see Reminders.swift for reminders).
// Exposes static functions returning JSON-safe [String: Any] dictionaries.
// Knows nothing about HTTP — Router.swift is the only caller.

import Foundation
import EventKit

enum Calendar_ {

    private static let store = EKEventStore()

    /// Call once at startup. Synchronous — blocks until the user responds
    /// to the permission dialog (or immediately if already decided).
    static func requestAccess(completion: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: { granted, _ in completion(granted) })
        } else {
            store.requestAccess(to: .event, completion: { granted, _ in completion(granted) })
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

    /// args: { "start": ISO8601 string?, "end": ISO8601 string? }
    /// Defaults to "now" through "7 days from now".
    static func list(args: [String: Any]) -> [String: Any] {
        let start = parseDate(args["start"]) ?? Date()
        let end = parseDate(args["end"]) ?? Date().addingTimeInterval(7 * 24 * 60 * 60)

        guard start <= end else {
            return ["ok": false, "error": "'start' must be before 'end'"]
        }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)

        let payload = events.map { event -> [String: Any] in
            [
                "id": event.eventIdentifier ?? "",
                "title": event.title ?? "",
                "start": isoString(event.startDate),
                "end": isoString(event.endDate),
                "location": event.location ?? "",
                "isAllDay": event.isAllDay,
                "calendar": event.calendar?.title ?? ""
            ]
        }

        return ["ok": true, "events": payload]
    }

    /// args: { "title": String, "start": ISO8601 string, "end": ISO8601 string,
    ///         "location": String?, "notes": String? }
    static func create(args: [String: Any]) -> [String: Any] {
        guard let title = args["title"] as? String, !title.isEmpty else {
            return ["ok": false, "error": "'title' is required"]
        }
        guard let start = parseDate(args["start"]) else {
            return ["ok": false, "error": "'start' is required and must be ISO8601"]
        }
        guard let end = parseDate(args["end"]) else {
            return ["ok": false, "error": "'end' is required and must be ISO8601"]
        }
        guard start <= end else {
            return ["ok": false, "error": "'start' must be before 'end'"]
        }
        guard let calendar = store.defaultCalendarForNewEvents else {
            return ["ok": false, "error": "No default calendar available — check Calendar permission"]
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.calendar = calendar
        event.location = args["location"] as? String
        event.notes = args["notes"] as? String

        do {
            try store.save(event, span: .thisEvent)
            return ["ok": true, "id": event.eventIdentifier ?? ""]
        } catch {
            return ["ok": false, "error": "Failed to save event: \(error.localizedDescription)"]
        }
    }

    /// args: { "id": String }  — the event's eventIdentifier
    static func delete(args: [String: Any]) -> [String: Any] {
        guard let id = args["id"] as? String, !id.isEmpty else {
            return ["ok": false, "error": "'id' is required"]
        }
        guard let event = store.event(withIdentifier: id) else {
            return ["ok": false, "error": "No event found with id \(id)"]
        }

        do {
            try store.remove(event, span: .thisEvent)
            return ["ok": true, "id": id]
        } catch {
            return ["ok": false, "error": "Failed to delete event: \(error.localizedDescription)"]
        }
    }
}
