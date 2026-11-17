import Foundation
import MuesliCore

/// A loaded day is independent of the selected search hit or playhead.
struct TimeTurnerDaySnapshot {
    private(set) var day: Date?
    private(set) var moments: [VisualMemoryItem] = []

    private(set) var displays: [String: String] = [:]
    private var momentsByDisplay: [String: [VisualMemoryItem]] = [:]

    func moments(for displayID: String?) -> [VisualMemoryItem] {
        guard let displayID else { return moments }
        return momentsByDisplay[displayID] ?? []
    }

    mutating func prepare(for requestedDay: Date, calendar: Calendar = .current) {
        guard let day, calendar.isDate(day, inSameDayAs: requestedDay) else {
            load([], on: requestedDay)
            return
        }
    }

    mutating func load(_ moments: [VisualMemoryItem], on day: Date) {
        self.day = day
        self.moments = moments
        displays = [:]
        momentsByDisplay = [:]
        for item in moments {
            guard let display = item.display else { continue }
            displays[display.uuid] = display.name
            momentsByDisplay[display.uuid, default: []].append(item)
        }
    }
}
