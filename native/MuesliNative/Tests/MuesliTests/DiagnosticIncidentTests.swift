import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("DiagnosticIncident")
struct DiagnosticIncidentTests {
    private let metadata = DiagnosticAppMetadata(
        appVersion: "1.2.3",
        buildNumber: "456",
        bundleID: "com.muesli.dev",
        displayName: "MuesliDev",
        macOSVersion: "15.5.0",
        architecture: "arm64"
    )

    @Test("schema v2 omits arbitrary error details and correlates by incident ID")
    func unknownErrorIsStrictlyRedacted() {
        let incidentID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let error = NSError(
            domain: "PrivateDomain./Users/alice@example.com",
            code: 42,
            userInfo: [
                NSLocalizedDescriptionKey: "Secret transcript at /Users/alice/private.wav?token=abc123"
            ]
        )
        let incident = DiagnosticIncident(
            id: incidentID,
            kind: .dictationTranscriptionFailed,
            stage: .standardDictationTranscribe,
            backendOption: .parakeetMultilingual,
            error: error,
            metadata: metadata
        )

        let params = incident.telemetryParameters
        #expect(incident.telemetryErrorID == "Muesli.Diagnostic.dictation_transcription_failed.unclassified")
        #expect(incident.telemetryCategory == .thrownException)
        #expect(incident.userImpact == .operationBlocked)
        #expect(params["diagnostic.schema_version"] == "2")
        #expect(params["diagnostic.incident_id"] == incidentID.uuidString)
        #expect(params["diagnostic.stage"] == "standard_dictation_transcribe")
        #expect(params["diagnostic.backend"] == "fluidaudio")
        #expect(params["diagnostic.model"] == "FluidInference/parakeet-tdt-0.6b-v3-coreml")
        #expect(params["diagnostic.error_known"] == "false")
        #expect(params["diagnostic.error_signature"] == "unclassified")
        #expect(params["diagnostic.error_area"] == "unknown")
        #expect(params["diagnostic.error_domain"] == nil)
        #expect(params["diagnostic.error_code"] == nil)
        #expect(params["diagnostic.error_summary"] == nil)
        #expect(params["diagnostic.app_version"] == nil)
        #expect(params["diagnostic.build_number"] == nil)
        #expect(params.keys.allSatisfy { !$0.hasPrefix("TelemetryDeck.") })

        let allOutput = params.values.joined(separator: " ") + incident.issueBody
        for forbidden in ["PrivateDomain", "/Users/", "alice", "private.wav", "token=", "Secret transcript"] {
            #expect(!allOutput.contains(forbidden))
        }
        #expect(incident.issueBody.contains("Incident ID: \(incidentID.uuidString)"))
        #expect(incident.issueBody.contains("Error domain: unclassified"))
        #expect(incident.issueBody.contains("private error details were omitted"))
        #expect(incident.errorDisplayIdentifier == "unclassified")
    }

    @Test("known internal error codes emit stable allowlisted fingerprints")
    func knownInternalErrorCodesIncludeMeaning() {
        let incident = DiagnosticIncident(
            kind: .dictationAudioFailed,
            stage: .dictationAudioSession,
            backendOption: nil,
            error: NSError(domain: "MicrophoneRecorder", code: 3),
            metadata: metadata
        )

        #expect(incident.telemetryErrorID == "Muesli.Diagnostic.dictation_audio_failed.microphonerecorder.3")
        #expect(incident.errorMeaning?.summary == "Preferred microphone input could not be selected")
        #expect(incident.errorMeaning?.area == "audio_route_selection")
        #expect(incident.telemetryParameters["diagnostic.error_known"] == "true")
        #expect(incident.telemetryParameters["diagnostic.error_signature"] == "microphonerecorder.3")
        #expect(incident.telemetryParameters["diagnostic.error_area"] == "audio_route_selection")
        #expect(incident.telemetryParameters["diagnostic.error_domain"] == "MicrophoneRecorder")
        #expect(incident.telemetryParameters["diagnostic.error_code"] == "3")
        #expect(incident.telemetryParameters["diagnostic.error_summary"] == nil)
        #expect(incident.issueBody.contains("Error meaning: Preferred microphone input could not be selected"))
        #expect(incident.errorDisplayIdentifier == "MicrophoneRecorder 3")
    }

    @Test("signature tokens collapse adjacent separators deterministically")
    func signatureTokensCollapseAdjacentSeparators() {
        #expect(DiagnosticErrorCatalog.signatureToken("Foo...Bar///Baz") == "foo_bar_baz")
    }

    @Test("observed FluidAudio not-loaded error has a specific fingerprint")
    func fluidAudioNotLoadedFingerprint() {
        let incident = DiagnosticIncident(
            kind: .dictationTranscriptionFailed,
            stage: .standardDictationTranscribe,
            backendOption: .parakeetMultilingual,
            error: NSError(domain: "MuesliNativeApp.FluidAudioTranscriber.TranscriberError", code: 0),
            metadata: metadata
        )

        #expect(incident.errorFingerprint.signature == "fluid_audio_models_not_loaded")
        #expect(incident.errorFingerprint.area == "transcription_model_state")
        #expect(incident.errorDomain == "FluidAudioTranscriber.TranscriberError")
        #expect(incident.errorCode == "0")
    }

    @Test("nil underlying errors use app-state category and allowlisted signature")
    func nilErrorUsesAppStateCategory() {
        let incident = DiagnosticIncident(
            kind: .streamingDictationStartFailed,
            stage: .nemotronStreamingStart,
            backendOption: .nemotron35Multilingual,
            error: nil,
            metadata: metadata
        )

        #expect(incident.telemetryCategory == .appState)
        #expect(incident.errorFingerprint.signature == "streaming_controller_start_failed")
        #expect(incident.telemetryErrorID == "Muesli.Diagnostic.streaming_dictation_start_failed.streaming_controller_start_failed")
        #expect(incident.telemetryParameters["diagnostic.error_known"] == "true")
        #expect(incident.telemetryParameters["diagnostic.error_domain"] == nil)
    }

    @Test("Nemotron cases map directly to stable fingerprints")
    func nemotronCasesUseStableFingerprints() {
        let cases: [(Error, String, String)] = [
            (NemotronRNNTError.notLoaded, "nemotron_models_not_loaded", "0"),
            (NemotronRNNTError.downloadFailed("private download detail"), "nemotron_download_failed", "1"),
            (NemotronRNNTError.preprocessingFailed("private preprocessing detail"), "nemotron_preprocessing_failed", "2"),
            (NemotronRNNTError.decodingFailed("private decoding detail"), "nemotron_decoding_failed", "3"),
        ]

        for (error, signature, code) in cases {
            let fingerprint = DiagnosticErrorCatalog.fingerprint(
                for: error,
                kind: .streamingDictationRuntimeFailed,
                stage: .nemotronStreamingRuntime
            )
            #expect(fingerprint.signature == signature)
            #expect(fingerprint.safeDomain == "NemotronRNNTError")
            #expect(fingerprint.safeCode == code)
            #expect(!fingerprint.summary.contains("private"))
        }
    }

    @Test("recording save failure is classified as degraded output")
    func recordingSaveFailureIsDegraded() {
        let incident = DiagnosticIncident(
            kind: .meetingRecordingSaveFailed,
            stage: .saveMeetingRecording,
            error: NSError(domain: "MeetingRecordingWriter", code: 3),
            metadata: metadata
        )

        #expect(incident.userImpact == .degradedResult)
        #expect(incident.telemetryParameters["diagnostic.user_impact"] == "degraded_result")
    }

    @Test("domain fallback covers Swift enum style diagnostic errors")
    func domainFallbackCoversSwiftEnumErrors() {
        let meaning = DiagnosticErrorCatalog.meaning(
            domain: "MuesliNativeApp.MeetingLifecycleError",
            code: "0"
        )

        #expect(meaning?.summary == "Meeting recording could not be saved")
        #expect(meaning?.area == "meeting_persistence")
    }

    @Test("allowlisted domains reject unrecognized codes")
    func allowlistedDomainRejectsUnknownCode() {
        let incident = DiagnosticIncident(
            kind: .meetingProcessingFailed,
            stage: .meetingStopProcessing,
            error: NSError(domain: "MuesliNativeApp.MeetingLifecycleError", code: 999),
            metadata: metadata
        )

        #expect(incident.errorFingerprint == .unclassified())
        #expect(incident.telemetryParameters["diagnostic.error_domain"] == nil)
        #expect(incident.telemetryParameters["diagnostic.error_code"] == nil)
    }

    @Test("broad system classifications omit domain and code")
    func broadSystemClassificationOmitsRawCode() {
        let incident = DiagnosticIncident(
            kind: .meetingProcessingFailed,
            stage: .meetingStopProcessing,
            error: NSError(domain: "NSCocoaErrorDomain", code: 123_456),
            metadata: metadata
        )

        #expect(incident.errorFingerprint.signature == "system_foundation")
        #expect(incident.telemetryParameters["diagnostic.error_domain"] == nil)
        #expect(incident.telemetryParameters["diagnostic.error_code"] == nil)
    }

    @Test("GitHub issue URL is prefilled")
    func githubIssueURLIsPrefilled() throws {
        let incident = DiagnosticIncident(
            kind: .manualReport,
            severity: .info,
            stage: .manualReport,
            backendOption: nil,
            error: nil,
            metadata: metadata
        )

        let url = try #require(incident.githubIssueURL)
        #expect(url.absoluteString.hasPrefix("https://github.com/Muesli-HQ/muesli/issues/new?"))
        #expect(url.absoluteString.contains("title="))
        #expect(url.absoluteString.contains("body="))
        #expect(DiagnosticIncident.githubIssueFallbackURL.absoluteString == "https://github.com/Muesli-HQ/muesli/issues/new")
    }
}

@Suite("DiagnosticIncidentReporter")
@MainActor
struct DiagnosticIncidentReporterTests {
    @Test("records telemetry and prompts once per kind per day")
    func recordsTelemetryAndThrottlesPrompt() throws {
        let appState = AppState()
        let suiteName = "DiagnosticIncidentReporterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var sent: [DiagnosticIncident] = []
        var prompted: [DiagnosticIncident] = []
        let reporter = DiagnosticIncidentReporter(
            appState: appState,
            defaults: defaults,
            telemetrySink: { sent.append($0) },
            automaticPromptEnabled: { true },
            onPrompt: { prompted.append($0) }
        )

        let first = reporter.record(
            kind: .dictationAudioFailed,
            stage: .dictationAudioSession,
            backend: nil,
            error: NSError(domain: "MicrophoneRecorder", code: 1)
        )
        #expect(sent.map(\.id) == [first.id])
        #expect(prompted.map(\.id) == [first.id])
        #expect(appState.pendingDiagnosticIncident?.id == first.id)

        appState.pendingDiagnosticIncident = nil
        let second = reporter.record(
            kind: .dictationAudioFailed,
            stage: .dictationAudioSession,
            backend: nil,
            error: NSError(domain: "MicrophoneRecorder", code: 2)
        )
        #expect(sent.map(\.id) == [first.id, second.id])
        #expect(prompted.map(\.id) == [first.id])
        #expect(appState.pendingDiagnosticIncident == nil)

        var restartedPrompted: [DiagnosticIncident] = []
        let restartedReporter = DiagnosticIncidentReporter(
            appState: appState,
            defaults: defaults,
            telemetrySink: { sent.append($0) },
            automaticPromptEnabled: { true },
            onPrompt: { restartedPrompted.append($0) }
        )
        let third = restartedReporter.record(
            kind: .dictationAudioFailed,
            stage: .dictationAudioSession,
            backend: nil,
            error: NSError(domain: "MicrophoneRecorder", code: 3)
        )
        #expect(sent.map(\.id) == [first.id, second.id, third.id])
        #expect(restartedPrompted.isEmpty)
        #expect(appState.pendingDiagnosticIncident == nil)
    }

    @Test("default-off automatic reporting still records telemetry")
    func defaultOffStillRecordsTelemetry() {
        let appState = AppState()
        var sent: [DiagnosticIncident] = []
        var prompted: [DiagnosticIncident] = []
        let reporter = DiagnosticIncidentReporter(
            appState: appState,
            telemetrySink: { sent.append($0) },
            onPrompt: { prompted.append($0) }
        )

        let incident = reporter.record(
            kind: .dictationTranscriptionFailed,
            stage: .standardDictationTranscribe
        )

        #expect(sent.map(\.id) == [incident.id])
        #expect(prompted.isEmpty)
        #expect(appState.pendingDiagnosticIncident == nil)

        reporter.recordManualReport()
        #expect(appState.pendingDiagnosticIncident?.kind == .manualReport)
    }
}
