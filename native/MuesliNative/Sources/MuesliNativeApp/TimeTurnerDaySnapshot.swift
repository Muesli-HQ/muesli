import Foundation
import MuesliCore

/// A loaded day is independent of the selected search hit or playhead.
struct TimeTurnerDaySnapshot {
    private(set) var day: Date?
    private(set) var moments: [VisualMemoryItem] = []

    mutating func prepare(for requestedDay: Date, calendar: Calendar = .current) {
        guard let day, calendar.isDate(day, inSameDayAs: requestedDay) else {
            self.day = requestedDay
            moments = []
            return
        }
    }

    mutating func load(_ moments: [VisualMemoryItem], on day: Date) {
        self.day = day
        self.moments = moments
    }
}
