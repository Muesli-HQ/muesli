import Foundation

@MainActor
final class SalesAssistEngine {
    private let configProvider: () -> AppConfig
    private let alertHandler: (SalesAssistAlert) -> Void
    private let activeAlertsChanged: ([SalesAssistAlert]) -> Void
    private let maxVisibleAlerts: Int
    private var activeAlerts: [SalesAssistAlert] = []
    private var snoozedUntilByFingerprint: [String: Date] = [:]
    private var dismissedFingerprints: Set<String> = []
    private var snoozedUntilByCueKey: [String: Date] = [:]
    private var dismissedCueKeys: Set<String> = []
    private var recentTranscriptLines: [String] = []
    private let detector = SalesAssistDetector()
    private let classifier = SalesAssistLLMClassifier()
    private var classifierTask: Task<Void, Never>?
    private var lastClassifierFingerprint: String?
    private var isDisabledForSession = false

    init(
        configProvider: @escaping () -> AppConfig,
        maxVisibleAlerts: Int = 2,
        alertHandler: @escaping (SalesAssistAlert) -> Void,
        activeAlertsChanged: @escaping ([SalesAssistAlert]) -> Void
    ) {
        self.configProvider = configProvider
        self.maxVisibleAlerts = maxVisibleAlerts
        self.alertHandler = alertHandler
        self.activeAlertsChanged = activeAlertsChanged
    }

    func reset() {
        classifierTask?.cancel()
        classifierTask = nil
        activeAlerts = []
        recentTranscriptLines = []
        snoozedUntilByFingerprint = [:]
        dismissedFingerprints = []
        snoozedUntilByCueKey = [:]
        dismissedCueKeys = []
        lastClassifierFingerprint = nil
        isDisabledForSession = false
        activeAlertsChanged([])
    }

    func handleTranscriptLine(_ line: String) {
        let config = configProvider()
        guard !isDisabledForSession else { return }
        guard config.salesAssistEnabled else { return }
        recentTranscriptLines.append(line)
        recentTranscriptLines = Array(recentTranscriptLines.suffix(10))

        let localAlerts = detector.detectAlerts(lines: recentTranscriptLines, config: config)
        let localAlert = localAlerts.first
        accept(alerts: localAlerts)
        scheduleClassifierIfNeeded(localAlert: localAlert, config: config)
    }

    func presentManual(alerts: [SalesAssistAlert]) {
        accept(alerts: alerts)
    }

    func handleAction(_ action: SalesAssistOverlayAction, for alert: SalesAssistAlert) -> [SalesAssistAlert] {
        switch action {
        case .disableForSession:
            isDisabledForSession = true
            classifierTask?.cancel()
            classifierTask = nil
            activeAlerts = []
            activeAlertsChanged([])
            return activeAlerts
        case .dismiss:
            dismissedFingerprints.insert(alert.fingerprint)
            dismissedCueKeys.insert(cueKey(alert))
        case .snooze:
            snoozedUntilByFingerprint[alert.fingerprint] = Date().addingTimeInterval(120)
            snoozedUntilByCueKey[cueKey(alert)] = Date().addingTimeInterval(120)
        case .useful:
            dismissedFingerprints.insert(alert.fingerprint)
            dismissedCueKeys.insert(cueKey(alert))
        case .notUseful:
            dismissedFingerprints.insert(alert.fingerprint)
            snoozedUntilByFingerprint[alert.fingerprint] = Date().addingTimeInterval(10 * 60)
            dismissedCueKeys.insert(cueKey(alert))
            snoozedUntilByCueKey[cueKey(alert)] = Date().addingTimeInterval(10 * 60)
        }
        activeAlerts.removeAll { $0.fingerprint == alert.fingerprint }
        activeAlertsChanged(activeAlerts)
        return activeAlerts
    }

    private func accept(alerts: [SalesAssistAlert]) {
        pruneExpiredSnoozes()
        let freshAlerts = alerts.filter { alert in
            guard dismissedFingerprints.contains(alert.fingerprint) == false else { return false }
            guard dismissedCueKeys.contains(cueKey(alert)) == false else { return false }
            guard let snoozedUntil = snoozedUntilByFingerprint[alert.fingerprint] else { return true }
            guard snoozedUntil <= Date() else { return false }
            guard let cueSnoozedUntil = snoozedUntilByCueKey[cueKey(alert)] else { return true }
            return cueSnoozedUntil <= Date()
        }
        guard !freshAlerts.isEmpty else { return }

        for alert in freshAlerts {
            alertHandler(alert)
            if let index = activeAlerts.firstIndex(where: { $0.fingerprint == alert.fingerprint }) {
                activeAlerts[index] = alert
            } else {
                activeAlerts.append(alert)
            }
        }
        activeAlerts = sortedAlerts(activeAlerts).prefix(maxVisibleAlerts).map { $0 }
        activeAlertsChanged(activeAlerts)
    }

    private func scheduleClassifierIfNeeded(localAlert: SalesAssistAlert?, config: AppConfig) {
        guard config.salesAssistAIEnabled else { return }
        guard detector.shouldAskClassifier(
            lines: recentTranscriptLines,
            localAlert: localAlert,
            config: config
        ) else { return }
        let transcript = recentTranscriptLines.joined(separator: "\n")
        let fingerprint = String(transcript.suffix(420))
        guard fingerprint != lastClassifierFingerprint else { return }
        lastClassifierFingerprint = fingerprint

        classifierTask?.cancel()
        classifierTask = Task { [weak self, classifier] in
            do {
                try await Task.sleep(nanoseconds: 650_000_000)
                guard !Task.isCancelled else { return }
                guard let alert = await classifier.classify(transcript: transcript, config: config) else { return }
                await MainActor.run {
                    self?.accept(alerts: [alert])
                }
            } catch {
                return
            }
        }
    }

    private func pruneExpiredSnoozes() {
        let now = Date()
        snoozedUntilByFingerprint = snoozedUntilByFingerprint.filter { $0.value > now }
        snoozedUntilByCueKey = snoozedUntilByCueKey.filter { $0.value > now }
    }

    private func sortedAlerts(_ alerts: [SalesAssistAlert]) -> [SalesAssistAlert] {
        alerts.sorted { lhs, rhs in
            let leftScore = priorityScore(lhs.priority)
            let rightScore = priorityScore(rhs.priority)
            if leftScore != rightScore { return leftScore > rightScore }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func priorityScore(_ priority: String) -> Int {
        switch priority.lowercased() {
        case "high": return 3
        case "low": return 1
        default: return 2
        }
    }

    private func cueKey(_ alert: SalesAssistAlert) -> String {
        "\(alert.kind)|\(alert.objection)".lowercased()
    }
}
