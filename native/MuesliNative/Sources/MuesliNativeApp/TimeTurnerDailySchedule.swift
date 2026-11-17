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

/// Persist the lease independently from successful generation and notification
/// delivery. A crash can delay a retry, but cannot consume the entire day.
struct TimeTurnerDailyAttempt: Codable {
    private(set) var slot = ""
    private(set) var token: UUID?
    private(set) var attempts = 0
    private(set) var completed = false
    private(set) var retryAt = Date.distantPast
    private(set) var firstAttemptAt: Date?

    mutating func begin(slot: String, now: Date) -> UUID? {
        if self.slot != slot { self = Self(); self.slot = slot }
        guard !completed, attempts < 3, now >= retryAt else { return nil }
        if attempts == 0 { firstAttemptAt = now }
        attempts += 1
        let token = UUID()
        self.token = token
        retryAt = now.addingTimeInterval(15 * 60)
        return token
    }

    mutating func finish(token: UUID, succeeded: Bool, now: Date) {
        guard self.token == token else { return }
        self.token = nil
        completed = succeeded
        retryAt = now.addingTimeInterval(Double(5 * 60 * (1 << max(0, attempts - 1))))
    }

    /// A validated manual result can satisfy a failed scheduled run, regardless
    /// of retry backoff. An older recap must not suppress today's inventory check.
    mutating func acceptPersisted(slot: String, generatedAt: Date) -> Bool {
        guard self.slot == slot, let firstAttemptAt, generatedAt >= firstAttemptAt else { return false }
        completed = true
        token = nil
        return true
    }
}
