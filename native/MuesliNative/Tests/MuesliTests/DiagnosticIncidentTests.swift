import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("DiagnosticIncident")
struct DiagnosticIncidentTests {

    @Test("sanitizes telemetry fields and avoids raw error messages")
    func sanitizesTelemetryFields() {
        let metadata = DiagnosticAppMetadata(
            appVersion: "1.2.3",
            buildNumber: "456",
            bundleID: "com.muesli.dev",
            displayName: "MuesliDev",
            macOSVersion: "15.5.0",
            architecture: "arm64"
        )
        let error = NSError(
            domain: "Test Domain /Users/private",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Secret transcript /Users/private/audio.wav"]
        )

        let incident = DiagnosticIncident(
            kind: .dictationTranscriptionFailed,
            stage: "standard dictation/transcribe",
            backend: "fluid audio",
            model: "FluidInference/parakeet tdt v3",
            error: error,
            metadata: metadata
        )

        let params = incident.telemetryParameters
        #expect(params["TelemetryDeck.Error.id"] == "Muesli.Diagnostic.dictation_transcription_failed")
        #expect(params["diagnostic.stage"] == "standard_dictation_transcribe")
        #expect(params["diagnostic.backend"] == "fluid_audio")
        #expect(params["diagnostic.model"] == "FluidInference/parakeet_tdt_v3")
        #expect(params["diagnostic.error_domain"] == "Test_Domain__Users_private")
        #expect(params["diagnostic.error_code"] == "42")
        #expect(params["diagnostic.error_summary"] == nil)
        #expect(params["diagnostic.error_area"] == nil)
        #expect(params.values.allSatisfy { !$0.contains("Secret transcript") })
        #expect(params.values.allSatisfy { !$0.contains("audio.wav") })
        #expect(params.values.allSatisfy { !$0.contains("/Users/") })
    }

    @Test("issue body contains allowlisted diagnostics only")
    func issueBodyAvoidsPrivatePayloads() {
        let metadata = DiagnosticAppMetadata(
            appVersion: "1.2.3",
            buildNumber: "456",
            bundleID: "com.muesli.dev",
            displayName: "MuesliDev",
            macOSVersion: "15.5.0",
            architecture: "arm64"
        )
        let error = NSError(
            domain: "MuesliTranscriptionRuntime",
            code: 7,
            userInfo: [
                NSLocalizedDescriptionKey: "Failed for meeting title and transcript text at /Users/example/private.wav"
            ]
        )

        let incident = DiagnosticIncident(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            kind: .meetingProcessingFailed,
            stage: "meeting_stop_processing",
            backend: "fluidaudio",
            model: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
            error: error,
            metadata: metadata
        )

        let body = incident.issueBody
        #expect(body.contains("Incident: meeting_processing_failed"))
        #expect(body.contains("Backend: fluidaudio"))
        #expect(body.contains("Model: FluidInference/parakeet-tdt-0.6b-v3-coreml"))
        #expect(body.contains("Error meaning: Unknown; use domain/code for lookup"))
        #expect(body.contains("Diagnostic area: unknown"))
        #expect(!body.contains("private.wav"))
        #expect(!body.contains("Failed for meeting title"))
        #expect(!body.contains("transcript text at"))
        #expect(!body.contains("Failed for"))
    }

    @Test("known internal error codes include privacy-safe meanings")
    func knownInternalErrorCodesIncludeMeaning() {
        let incident = DiagnosticIncident(
            kind: .dictationAudioFailed,
            stage: "dictation_audio_session",
            backend: nil,
            error: NSError(domain: "MicrophoneRecorder", code: 3),
            metadata: DiagnosticAppMetadata(
                appVersion: "1.2.3",
                buildNumber: "456",
                bundleID: "com.muesli.dev",
                displayName: "MuesliDev",
                macOSVersion: "15.5.0",
                architecture: "arm64"
            )
        )

        #expect(incident.errorMeaning?.summary == "Preferred microphone input could not be selected")
        #expect(incident.errorMeaning?.area == "audio_route_selection")
        #expect(incident.telemetryParameters["diagnostic.error_summary"] == "Preferred microphone input could not be selected")
        #expect(incident.telemetryParameters["diagnostic.error_area"] == "audio_route_selection")
        #expect(incident.issueBody.contains("Error meaning: Preferred microphone input could not be selected"))
        #expect(incident.issueBody.contains("Diagnostic area: audio_route_selection"))
    }

    @Test("domain fallback covers Swift enum style diagnostic errors")
    func domainFallbackCoversSwiftEnumErrors() {
        let meaning = DiagnosticErrorCatalog.meaning(
            domain: "MuesliNativeApp.MeetingLifecycleError",
            code: "0"
        )

        #expect(meaning?.summary == "Meeting lifecycle persistence failed")
        #expect(meaning?.area == "meeting_persistence")
    }

    @Test("GitHub issue URL is prefilled")
    func githubIssueURLIsPrefilled() throws {
        let incident = DiagnosticIncident(
            kind: .manualReport,
            severity: .info,
            stage: "manual_report",
            backend: nil,
            error: nil,
            metadata: DiagnosticAppMetadata(
                appVersion: "1.2.3",
                buildNumber: "456",
                bundleID: "com.muesli.dev",
                displayName: "MuesliDev",
                macOSVersion: "15.5.0",
                architecture: "arm64"
            )
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
            onPrompt: { prompted.append($0) }
        )

        let first = reporter.record(
            kind: .dictationAudioFailed,
            stage: "dictation_audio_session",
            backend: nil,
            error: NSError(domain: "Recorder", code: 1)
        )
        #expect(sent.map(\.id) == [first.id])
        #expect(prompted.map(\.id) == [first.id])
        #expect(appState.pendingDiagnosticIncident?.id == first.id)

        appState.pendingDiagnosticIncident = nil
        let second = reporter.record(
            kind: .dictationAudioFailed,
            stage: "dictation_audio_session",
            backend: nil,
            error: NSError(domain: "Recorder", code: 2)
        )
        #expect(sent.map(\.id) == [first.id, second.id])
        #expect(prompted.map(\.id) == [first.id])
        #expect(appState.pendingDiagnosticIncident == nil)

        var restartedPrompted: [DiagnosticIncident] = []
        let restartedReporter = DiagnosticIncidentReporter(
            appState: appState,
            defaults: defaults,
            telemetrySink: { sent.append($0) },
            onPrompt: { restartedPrompted.append($0) }
        )
        let third = restartedReporter.record(
            kind: .dictationAudioFailed,
            stage: "dictation_audio_session",
            backend: nil,
            error: NSError(domain: "Recorder", code: 3)
        )
        #expect(sent.map(\.id) == [first.id, second.id, third.id])
        #expect(restartedPrompted.isEmpty)
        #expect(appState.pendingDiagnosticIncident == nil)
    }
}
