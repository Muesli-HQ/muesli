import Foundation

enum DiagnosticIncidentKind: String, Codable, CaseIterable, Sendable {
    case manualReport = "manual_report"
    case dictationAudioFailed = "dictation_audio_failed"
    case dictationTranscriptionFailed = "dictation_transcription_failed"
    case streamingDictationStartFailed = "streaming_dictation_start_failed"
    case streamingDictationRuntimeFailed = "streaming_dictation_runtime_failed"
    case meetingStartFailed = "meeting_start_failed"
    case meetingMicrophoneCaptureFailed = "meeting_microphone_capture_failed"
    case meetingProcessingFailed = "meeting_processing_failed"
    case meetingRecordingSaveFailed = "meeting_recording_save_failed"

    var title: String {
        switch self {
        case .manualReport: return "Manual problem report"
        case .dictationAudioFailed: return "Dictation audio capture failed"
        case .dictationTranscriptionFailed: return "Dictation transcription failed"
        case .streamingDictationStartFailed: return "Streaming dictation failed to start"
        case .streamingDictationRuntimeFailed: return "Streaming dictation failed"
        case .meetingStartFailed: return "Meeting recording failed to start"
        case .meetingMicrophoneCaptureFailed: return "Meeting microphone capture failed"
        case .meetingProcessingFailed: return "Meeting processing failed"
        case .meetingRecordingSaveFailed: return "Meeting recording save failed"
        }
    }

    var userImpact: DiagnosticUserImpact {
        switch self {
        case .manualReport: return .informational
        case .meetingRecordingSaveFailed, .meetingMicrophoneCaptureFailed: return .degradedResult
        default: return .operationBlocked
        }
    }

    func telemetryErrorID(signature: String) -> String {
        "Muesli.Diagnostic.\(rawValue).\(signature)"
    }
}

enum DiagnosticIncidentStage: String, Codable, CaseIterable, Sendable {
    case manualReport = "manual_report"
    case createLiveMeeting = "create_live_meeting"
    case startMeetingRecording = "start_meeting_recording"
    case meetingMicrophoneCapture = "meeting_microphone_capture"
    case saveMeetingRecording = "save_meeting_recording"
    case meetingStopProcessing = "meeting_stop_processing"
    case dictationAudioSession = "dictation_audio_session"
    case nemotronStreamingStart = "nemotron_streaming_start"
    case nemotronStreamingRuntime = "nemotron_streaming_runtime"
    case standardDictationTranscribe = "standard_dictation_transcribe"
}

enum DiagnosticIncidentSeverity: String, Codable, Sendable {
    case info
    case warning
    case error
}

enum DiagnosticUserImpact: String, Codable, Sendable {
    case operationBlocked = "operation_blocked"
    case degradedResult = "degraded_result"
    case informational
}

enum DiagnosticTelemetryCategory: String, Codable, Sendable {
    case thrownException = "thrown-exception"
    case appState = "app-state"
}

struct DiagnosticAppMetadata: Codable, Equatable, Sendable {
    let appVersion: String
    let buildNumber: String
    let bundleID: String
    let displayName: String
    let macOSVersion: String
    let architecture: String

    static func current() -> DiagnosticAppMetadata {
        let bundle = Bundle.main
        return DiagnosticAppMetadata(
            appVersion: sanitizedBundleValue("CFBundleShortVersionString", in: bundle),
            buildNumber: sanitizedBundleValue("CFBundleVersion", in: bundle),
            bundleID: bundle.bundleIdentifier ?? "unknown",
            displayName: AppIdentity.displayName,
            macOSVersion: macOSVersionString(),
            architecture: machineArchitecture()
        )
    }

    private static func sanitizedBundleValue(_ key: String, in bundle: Bundle) -> String {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String else { return "unknown" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    private static func macOSVersionString() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func machineArchitecture() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "unknown"
            }
        }
    }
}

struct DiagnosticIncident: Codable, Equatable, Identifiable, Sendable {
    static let telemetrySchemaVersion = "2"

    let id: UUID
    let kind: DiagnosticIncidentKind
    let severity: DiagnosticIncidentSeverity
    let occurredAt: Date
    let stage: DiagnosticIncidentStage
    let userImpact: DiagnosticUserImpact
    let backend: String
    let model: String
    let errorFingerprint: DiagnosticErrorFingerprint
    let telemetryCategory: DiagnosticTelemetryCategory
    let metadata: DiagnosticAppMetadata

    var telemetryErrorID: String {
        kind.telemetryErrorID(signature: errorFingerprint.signature)
    }

    var errorMeaning: DiagnosticErrorMeaning? {
        errorFingerprint.isKnown
            ? DiagnosticErrorMeaning(summary: errorFingerprint.summary, area: errorFingerprint.area)
            : nil
    }

    var errorDomain: String { errorFingerprint.safeDomain ?? "unclassified" }
    var errorCode: String { errorFingerprint.safeCode ?? "unclassified" }
    var errorDisplayIdentifier: String {
        guard let domain = errorFingerprint.safeDomain,
              let code = errorFingerprint.safeCode else {
            return errorFingerprint.signature
        }
        return "\(domain) \(code)"
    }

    init(
        id: UUID = UUID(),
        kind: DiagnosticIncidentKind,
        severity: DiagnosticIncidentSeverity = .error,
        occurredAt: Date = Date(),
        stage: DiagnosticIncidentStage,
        backendOption: BackendOption? = nil,
        error: Error? = nil,
        metadata: DiagnosticAppMetadata = .current()
    ) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.occurredAt = occurredAt
        self.stage = stage
        self.userImpact = kind.userImpact
        self.backend = backendOption?.backend ?? "unknown"
        self.model = backendOption?.model ?? "unknown"
        self.errorFingerprint = DiagnosticErrorCatalog.fingerprint(for: error, kind: kind, stage: stage)
        self.telemetryCategory = error == nil ? .appState : .thrownException
        self.metadata = metadata
    }

    var telemetryParameters: [String: String] {
        var parameters = [
            "diagnostic.schema_version": Self.telemetrySchemaVersion,
            "diagnostic.incident_id": id.uuidString,
            "diagnostic.kind": kind.rawValue,
            "diagnostic.severity": severity.rawValue,
            "diagnostic.stage": stage.rawValue,
            "diagnostic.user_impact": userImpact.rawValue,
            "diagnostic.backend": backend,
            "diagnostic.model": model,
            "diagnostic.error_known": String(errorFingerprint.isKnown),
            "diagnostic.error_signature": errorFingerprint.signature,
            "diagnostic.error_area": errorFingerprint.area,
        ]
        if let safeDomain = errorFingerprint.safeDomain, let safeCode = errorFingerprint.safeCode {
            parameters["diagnostic.error_domain"] = safeDomain
            parameters["diagnostic.error_code"] = safeCode
        }
        return parameters
    }

    var issueTitle: String {
        "[Diagnostic] \(kind.title)"
    }

    var issueBody: String {
        """
        ### What happened?
        Please describe what you were trying to do and what you expected to happen.

        ### Privacy
        This report was generated from an allowlisted diagnostic summary. It does not include transcripts, audio, meeting titles, calendar titles, clipboard contents, screen/OCR text, API keys, auth tokens, local file paths, raw error messages, raw logs, or database contents.

        ### Anonymized diagnostics
        - Incident: \(kind.rawValue)
        - Severity: \(severity.rawValue)
        - User impact: \(userImpact.rawValue)
        - Stage: \(stage.rawValue)
        - App: \(metadata.displayName)
        - Version: \(metadata.appVersion)
        - Build: \(metadata.buildNumber)
        - Bundle ID: \(metadata.bundleID)
        - macOS: \(metadata.macOSVersion)
        - Architecture: \(metadata.architecture)
        - Backend: \(backend)
        - Model: \(model)
        - Error signature: \(errorFingerprint.signature)
        - Error domain: \(errorDomain)
        - Error code: \(errorCode)
        - Error meaning: \(errorFingerprint.summary)
        - Diagnostic area: \(errorFingerprint.area)
        - Incident ID: \(id.uuidString)
        """
    }

    var githubIssueURL: URL? {
        var components = URLComponents(string: "https://github.com/Muesli-HQ/muesli/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: issueTitle),
            URLQueryItem(name: "body", value: issueBody),
        ]
        return components?.url
    }

    static let githubIssueFallbackURL = URL(string: "https://github.com/Muesli-HQ/muesli/issues/new")!

}
