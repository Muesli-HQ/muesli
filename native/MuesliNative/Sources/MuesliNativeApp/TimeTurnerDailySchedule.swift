import Foundation

/// Calendar arithmetic keeps the recap pinned to the selected local day across DST.
struct TimeTurnerDailySchedule {
    let slot: String
    let target: Date

    init?(config: AppConfig, now: Date, calendar: Calendar = .current) {
        guard config.timeTurnerEnabled, ["previous", "today"].contains(config.recapSchedule),
              let hour = Int(config.recapScheduleHour), (0..<24).contains(hour),
              calendar.component(.hour, from: now) >= hour else { return nil }
        let day = calendar.startOfDay(for: now)
        guard let target = calendar.date(byAdding: .day, value: config.recapSchedule == "previous" ? -1 : 0, to: day) else { return nil }
        self.target = target
        slot = SavedTimeTurnerRecap.key(dayStart: day, timeZone: calendar.timeZone.identifier) + "|" + config.recapSchedule + "|" + String(hour)
    }
}
