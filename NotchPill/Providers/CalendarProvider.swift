import Foundation
import EventKit

/// Provides the next upcoming calendar event via EventKit. Requests access
/// lazily; if access is denied or restricted it simply publishes nil so the
/// tile is omitted rather than showing stale data.
final class CalendarProvider {
    var onUpdate: ((CalendarEvent?) -> Void)?

    private let store = EKEventStore()
    private var refreshTimer: Timer?

    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged),
                                               name: .EKEventStoreChanged, object: store)
        requestAccessAndLoad()
        // Re-evaluate periodically so a passed event rolls to the next one.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.load()
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func storeChanged() { load() }

    private func requestAccessAndLoad() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            guard let self else { return }
            if granted { self.load() } else { self.publish(nil) }
        }
    }

    private func load() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            publish(nil); return
        }

        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now.addingTimeInterval(604800)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let next = store.events(matching: predicate)
            .filter { $0.endDate > now && !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .first

        if let event = next {
            publish(CalendarEvent(title: event.title ?? "Event",
                                  start: event.startDate,
                                  location: event.location,
                                  isAllDay: event.isAllDay))
        } else {
            publish(nil)
        }
    }

    private func publish(_ event: CalendarEvent?) {
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(event) }
    }
}
