#if DEBUG
import Foundation
import TelemetryDeck

/// One-shot manual QA for the Debug Dev C app only. No persistent settings,
/// microphone permissions, device state, or production telemetry are changed.
final class DictationDevFaults: @unchecked Sendable {
    enum Fault: String, Sendable {
        case microphoneStartup = "mic-startup"
        case streamingFinalization = "streaming"
    }
    static let environmentKey = "MUESLI_DEV_DICTATION_FAULT"
    private let lock = NSLock()
    private let fault: Fault
    private var consumed = false
    private let onTrigger: ((Fault) -> Void)?

    init(_ fault: Fault, onTrigger: ((Fault) -> Void)? = nil) {
        self.fault = fault
        self.onTrigger = onTrigger
    }

    static func fromProcess(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleID: String? = Bundle.main.bundleIdentifier,
        telemetryChannel: String? = Bundle.main.object(forInfoDictionaryKey: "MuesliTelemetryChannel") as? String
    ) -> DictationDevFaults? {
        guard bundleID == "com.muesli.dev.c", telemetryChannel == "dev",
              let value = environment[environmentKey], let fault = Fault(rawValue: value) else { return nil }
        return DictationDevFaults(fault) { fault in
            // Fixed enum only; never include content, identifiers or error text.
            MuesliTelemetry.signal("dictation.dev_fault.triggered", parameters: ["fault": fault.rawValue])
        }
    }

    var skipsMicrophoneWarmup: Bool {
        lock.withLock { fault == .microphoneStartup && !consumed }
    }

    func consume(_ expected: Fault) -> Bool {
        let didConsume = lock.withLock {
            guard fault == expected, !consumed else { return false }
            consumed = true
            return true
        }
        if didConsume { onTrigger?(expected) }
        return didConsume
    }

    @MainActor
    func streamingFailure(partialText: @autoclosure () -> String) -> BufferedDictationFinalizer.IncompleteStream? {
        guard consume(.streamingFinalization) else { return nil }
        return .init(reason: "dev_injected_finalization_failure", partialText: partialText())
    }

    static var startupStall: TimeInterval { DictationStartupWatchdog.defaultWarningDelay + 1 }
}
#endif
