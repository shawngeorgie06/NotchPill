import Foundation
import EventKit

/// Provides the next upcoming calendar event via EventKit. Requests access
/// lazily; if access is denied or restricted it simply publishes nil so the
/// tile is omitted rather than showing stale data.
final class CalendarProvider {
    var onUpdate: ((CalendarEvent?) -> Void)?

    private let store = EKEventStore()
    private var refreshTimer: Timer?
    private var isRunning = false
    private var generation = 0

    func start() {
        guard !isRunning else { return }
        isRunning = true
        generation &+= 1
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged),
                                               name: .EKEventStoreChanged, object: store)
        requestAccessAndLoad(generation: generation)
        // Re-evaluate periodically so a passed event rolls to the next one.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.load()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation &+= 1
        refreshTimer?.invalidate()
        refreshTimer = nil
        NotificationCenter.default.removeObserver(self, name: .EKEventStoreChanged, object: store)
        onUpdate?(nil)
    }

    @objc private func storeChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.load()
        }
    }

    private func requestAccessAndLoad(generation: Int) {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self, self.isRunning, self.generation == generation else { return }
                if granted { self.load() } else { self.publish(nil, generation: generation) }
            }
        }
    }

    private func load() {
        guard isRunning else { return }
        let loadGeneration = generation
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            publish(nil, generation: loadGeneration); return
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
                                  isAllDay: event.isAllDay), generation: loadGeneration)
        } else {
            publish(nil, generation: loadGeneration)
        }
    }

    private func publish(_ event: CalendarEvent?, generation: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning, self.generation == generation else { return }
            self.onUpdate?(event)
        }
    }
}
