import Foundation

enum DiagnosticIncidentKind: String, Codable, CaseIterable, Sendable {
    case manualReport = "manual_report"
    case dictationAudioFailed = "dictation_audio_failed"
    case dictationTranscriptionFailed = "dictation_transcription_failed"
    case streamingDictationStartFailed = "streaming_dictation_start_failed"
    case streamingDictationRuntimeFailed = "streaming_dictation_runtime_failed"
    case meetingStartFailed = "meeting_start_failed"
    case meetingProcessingFailed = "meeting_processing_failed"
    case meetingRecordingSaveFailed = "meeting_recording_save_failed"

    var title: String {
        switch self {
        case .manualReport:
            return "Manual problem report"
        case .dictationAudioFailed:
            return "Dictation audio capture failed"
        case .dictationTranscriptionFailed:
            return "Dictation transcription failed"
        case .streamingDictationStartFailed:
            return "Streaming dictation failed to start"
        case .streamingDictationRuntimeFailed:
            return "Streaming dictation failed"
        case .meetingStartFailed:
            return "Meeting recording failed to start"
        case .meetingProcessingFailed:
            return "Meeting processing failed"
        case .meetingRecordingSaveFailed:
            return "Meeting recording save failed"
        }
    }

    var telemetryErrorID: String {
        "Muesli.Diagnostic.\(rawValue)"
    }
}

enum DiagnosticIncidentSeverity: String, Codable, Sendable {
    case info
    case warning
    case error
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
            macOSVersion: Self.macOSVersionString(),
            architecture: Self.machineArchitecture()
        )
    }

    var macOSMajorMinor: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }

    private static func sanitizedBundleValue(_ key: String, in bundle: Bundle) -> String {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String else {
            return "unknown"
        }
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
    let id: UUID
    let kind: DiagnosticIncidentKind
    let severity: DiagnosticIncidentSeverity
    let occurredAt: Date
    let stage: String
    let backend: String
    let model: String
    let errorDomain: String
    let errorCode: String
    let metadata: DiagnosticAppMetadata

    var errorMeaning: DiagnosticErrorMeaning? {
        DiagnosticErrorCatalog.meaning(domain: errorDomain, code: errorCode)
    }

    init(
        id: UUID = UUID(),
        kind: DiagnosticIncidentKind,
        severity: DiagnosticIncidentSeverity = .error,
        occurredAt: Date = Date(),
        stage: String,
        backend: String? = nil,
        model: String? = nil,
        error: Error? = nil,
        metadata: DiagnosticAppMetadata = .current()
    ) {
        let nsError = error as NSError?
        self.id = id
        self.kind = kind
        self.severity = severity
        self.occurredAt = occurredAt
        self.stage = DiagnosticIncident.sanitizeToken(stage)
        self.backend = DiagnosticIncident.sanitizeToken(backend ?? "unknown")
        self.model = DiagnosticIncident.sanitizeModelIdentifier(model ?? "unknown")
        self.errorDomain = DiagnosticIncident.sanitizeToken(nsError?.domain ?? "none")
        self.errorCode = DiagnosticIncident.sanitizeToken(nsError.map { String($0.code) } ?? "none")
        self.metadata = metadata
    }

    init(
        id: UUID = UUID(),
        kind: DiagnosticIncidentKind,
        severity: DiagnosticIncidentSeverity = .error,
        occurredAt: Date = Date(),
        stage: String,
        backendOption: BackendOption?,
        error: Error? = nil,
        metadata: DiagnosticAppMetadata = .current()
    ) {
        self.init(
            id: id,
            kind: kind,
            severity: severity,
            occurredAt: occurredAt,
            stage: stage,
            backend: backendOption?.backend,
            model: backendOption?.model,
            error: error,
            metadata: metadata
        )
    }

    var telemetryParameters: [String: String] {
        var parameters = [
            "TelemetryDeck.Error.id": kind.telemetryErrorID,
            "TelemetryDeck.Error.category": "thrown-exception",
            "diagnostic.kind": kind.rawValue,
            "diagnostic.severity": severity.rawValue,
            "diagnostic.stage": stage,
            "diagnostic.backend": backend,
            "diagnostic.model": model,
            "diagnostic.error_domain": errorDomain,
            "diagnostic.error_code": errorCode,
            "diagnostic.bundle_id": metadata.bundleID,
            "diagnostic.app_version": metadata.appVersion,
            "diagnostic.build_number": metadata.buildNumber,
            "diagnostic.macos_major_minor": metadata.macOSMajorMinor,
            "diagnostic.architecture": metadata.architecture,
        ]
        if let errorMeaning {
            parameters["diagnostic.error_summary"] = errorMeaning.summary
            parameters["diagnostic.error_area"] = errorMeaning.area
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
        This report was generated from an allowlisted diagnostic summary. It does not include transcripts, audio, meeting titles, calendar titles, clipboard contents, screen/OCR text, API keys, auth tokens, local file paths, raw logs, or database contents.

        ### Anonymized diagnostics
        - Incident: \(kind.rawValue)
        - Severity: \(severity.rawValue)
        - Stage: \(stage)
        - App: \(metadata.displayName)
        - Version: \(metadata.appVersion)
        - Build: \(metadata.buildNumber)
        - Bundle ID: \(metadata.bundleID)
        - macOS: \(metadata.macOSVersion)
        - Architecture: \(metadata.architecture)
        - Backend: \(backend)
        - Model: \(model)
        - Error domain: \(errorDomain)
        - Error code: \(errorCode)
        - Error meaning: \(errorMeaning?.summary ?? "Unknown; use domain/code for lookup")
        - Diagnostic area: \(errorMeaning?.area ?? "unknown")
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

    static func sanitizeToken(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        let scalars = value.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
        let filtered = String(String.UnicodeScalarView(scalars.map { allowed.contains($0) ? $0 : "_" }))
        return filtered.isEmpty ? "unknown" : String(filtered.prefix(160))
    }

    static func sanitizeModelIdentifier(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-/")
        let scalars = value.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
        let filtered = String(String.UnicodeScalarView(scalars.map { allowed.contains($0) ? $0 : "_" }))
        return filtered.isEmpty ? "unknown" : String(filtered.prefix(160))
    }
}
