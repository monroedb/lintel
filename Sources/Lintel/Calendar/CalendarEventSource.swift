import EventKit
import Foundation
import LintelCore

/// Calendar access as Lintel sees it (EventKit full access).
enum CalendarAccess: String {
    case notDetermined, denied, restricted, writeOnly, fullAccess

    var canRead: Bool { self == .fullAccess }
}

/// Where events come from: EventKit.
@MainActor
protocol CalendarEventSource: AnyObject {
    var name: String { get }
    var access: CalendarAccess { get }
    /// Called when the store's contents change (`EKEventStoreChanged`).
    var onChange: (() -> Void)? { get set }
    func requestAccess() async -> CalendarAccess
    func calendars() -> [CalendarListEntry]
    func events(from start: Date, to end: Date) async -> [CalendarEventRecord]
}

/// EventKit, read-only. Lintel never creates, edits or deletes events or calendars.
@MainActor
final class EventKitCalendarSource: CalendarEventSource {
    let name = "eventkit"
    var onChange: (() -> Void)?
    private var box = EventStoreBox()
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    var access: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .fullAccess: return .fullAccess
        case .writeOnly: return .writeOnly
        @unknown default: return .denied
        }
    }

    func requestAccess() async -> CalendarAccess {
        let store = box
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // @Sendable: EventKit may call back off the main thread (no main-actor isolation to check).
            store.store.requestFullAccessToEvents { @Sendable _, _ in continuation.resume() }
        }
        // A store created before access was granted doesn't see the calendars; start a fresh one.
        box = EventStoreBox()
        return access
    }

    func calendars() -> [CalendarListEntry] {
        guard access.canRead else { return [] }
        return box.store.calendars(for: .event).map { calendar in
            CalendarListEntry(id: calendar.calendarIdentifier, title: calendar.title,
                              color: EventColor(cgColor: calendar.cgColor) ?? .copper, account: calendar.source?.title ?? "")
        }
    }

    func events(from start: Date, to end: Date) async -> [CalendarEventRecord] {
        guard access.canRead, end > start else { return [] }
        let store = box
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let predicate = store.store.predicateForEvents(withStart: start, end: end, calendars: nil)
                let records = store.store.events(matching: predicate).compactMap(Self.record(from:))
                continuation.resume(returning: records)
            }
        }
    }

    /// Normalises an EventKit occurrence. Notes are only scanned for a meeting link, never kept.
    nonisolated static func record(from event: EKEvent) -> CalendarEventRecord? {
        guard let start = event.startDate, let end = event.endDate, let calendar = event.calendar else { return nil }
        let declined = event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
        let kind: CalendarEventKind
        if calendar.type == .birthday {
            kind = .birthday
        } else if calendar.type == .subscription, calendar.title.localizedCaseInsensitiveContains("holiday") {
            kind = .holiday
        } else {
            kind = .regular
        }
        let geo = event.structuredLocation?.geoLocation?.coordinate
        let base = event.eventIdentifier ?? event.calendarItemIdentifier
        return CalendarEventRecord(
            id: "\(base)@\(Int(start.timeIntervalSince1970))",
            externalID: event.calendarItemExternalIdentifier,
            calendarID: calendar.calendarIdentifier,
            title: (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            start: start, end: end, isAllDay: event.isAllDay,
            location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines),
            latitude: geo?.latitude, longitude: geo?.longitude,
            color: EventColor(cgColor: calendar.cgColor) ?? .copper,
            kind: kind, declined: declined, cancelled: event.status == .canceled,
            meeting: MeetingLinkDetector.detect(url: event.url?.absoluteString, location: event.location, notes: event.notes)
        )
    }
}

/// Lets the store be used from the fetch queue (EventKit stores may be read from any thread).
private final class EventStoreBox: @unchecked Sendable {
    let store = EKEventStore()
}
