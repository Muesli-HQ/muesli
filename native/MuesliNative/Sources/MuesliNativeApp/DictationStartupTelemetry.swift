import TelemetryDeck

enum DictationStartupTelemetry {
    static func send(_ report: DictationStartupReport) {
        TelemetryDeck.signal(report.eventName, parameters: report.telemetryParameters)
        if report.outcome == .failed && report.failureReason != .none, report.failureReason != .recorderError {
            TelemetryDeck.errorOccurred(id: "microphone_capture_failed", category: .appState,
                message: nil, parameters: report.telemetryParameters)
        }
    }
}
