import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("OnboardingProgress")
struct OnboardingProgressTests {

    @Test("missing Cohere language defaults to english")
    func missingCohereLanguageDefaultsToEnglish() throws {
        let json = """
        {
          "schemaVersion": 2,
          "currentStep": 3,
          "userName": "Test User",
          "selectedBackendKey": "cohere",
          "selectedModelKey": "phequals/cohere-transcribe-coreml-mixed-precision",
          "hotkeyKeyCode": 55,
          "hotkeyLabel": "Left Cmd",
          "systemAudioRequested": true
        }
        """

        let progress = try JSONDecoder().decode(OnboardingProgress.self, from: Data(json.utf8))

        #expect(progress.selectedCohereLanguageCode == CohereTranscribeLanguage.english.rawValue)
    }

    @Test("unsupported Cohere language is normalized")
    func unsupportedCohereLanguageFallsBackToEnglish() throws {
        let json = """
        {
          "schemaVersion": 3,
          "currentStep": 1,
          "userName": "Test User",
          "selectedBackendKey": "cohere",
          "selectedModelKey": "phequals/cohere-transcribe-coreml-mixed-precision",
          "selectedCohereLanguageCode": "xx",
          "hotkeyKeyCode": 55,
          "hotkeyLabel": "Left Cmd"
        }
        """

        let progress = try JSONDecoder().decode(OnboardingProgress.self, from: Data(json.utf8))

        #expect(progress.selectedCohereLanguageCode == CohereTranscribeLanguage.english.rawValue)
    }

    @Test("missing onboarding use case defaults to dictation")
    func missingOnboardingUseCaseDefaultsToDictation() throws {
        let json = """
        {
          "schemaVersion": 3,
          "currentStep": 1,
          "userName": "Test User",
          "selectedBackendKey": "fluidaudio",
          "selectedModelKey": "FluidInference/parakeet-tdt-0.6b-v3-coreml",
          "hotkeyKeyCode": 55,
          "hotkeyLabel": "Left Cmd"
        }
        """

        let progress = try JSONDecoder().decode(OnboardingProgress.self, from: Data(json.utf8))

        #expect(progress.onboardingUseCaseRawValue == OnboardingUseCase.dictation.rawValue)
    }

    @Test("model download display progress round-trips")
    func modelDownloadDisplayProgressRoundTrips() throws {
        let progress = OnboardingProgress(
            currentStep: 4,
            userName: "Test User",
            selectedBackendKey: "fluidaudio",
            selectedModelKey: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
            hotkeyKeyCode: 55,
            hotkeyLabel: "Left Cmd",
            modelDownloadProgress: 0.42,
            modelDownloadStatus: "189 MB of 450 MB"
        )

        let data = try JSONEncoder().encode(progress)
        let decoded = try JSONDecoder().decode(OnboardingProgress.self, from: data)

        #expect(decoded.modelDownloadProgress == 0.42)
        #expect(decoded.modelDownloadStatus == "189 MB of 450 MB")
    }

    @Test("dictation monitor starts at and after its resume threshold")
    func dictationMonitorUsesResumeThreshold() {
        let threshold = OnboardingFlow.dictationTestStep

        #expect(!OnboardingFlow.shouldStartDictationTestMonitor(
            currentStep: threshold - 1,
            dictationTestStep: threshold,
            modelReady: true
        ))
        #expect(OnboardingFlow.shouldStartDictationTestMonitor(
            currentStep: threshold,
            dictationTestStep: threshold,
            modelReady: true
        ))
        #expect(OnboardingFlow.shouldStartDictationTestMonitor(
            currentStep: threshold + 1,
            dictationTestStep: threshold,
            modelReady: true
        ))
        #expect(!OnboardingFlow.shouldStartDictationTestMonitor(
            currentStep: threshold,
            dictationTestStep: threshold,
            modelReady: false
        ))
    }

    @Test("dictation test resume threshold persists through decode and round trip")
    func dictationTestResumeThresholdPersists() throws {
        let threshold = OnboardingFlow.dictationTestStep
        #expect(threshold == 4)

        let json = """
        {
          "schemaVersion": 3,
          "currentStep": 4,
          "userName": "Test User",
          "selectedBackendKey": "fluidaudio",
          "selectedModelKey": "FluidInference/parakeet-tdt-0.6b-v3-coreml",
          "hotkeyKeyCode": 55,
          "hotkeyLabel": "Left Cmd"
        }
        """
        let decoded = try JSONDecoder().decode(OnboardingProgress.self, from: Data(json.utf8))
        #expect(decoded.currentStep == threshold)

        for step in [threshold - 1, threshold, threshold + 1] {
            let progress = OnboardingProgress(
                currentStep: step,
                userName: "Test User",
                selectedBackendKey: "fluidaudio",
                selectedModelKey: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
                hotkeyKeyCode: 55,
                hotkeyLabel: "Left Cmd"
            )
            let roundTripped = try JSONDecoder().decode(
                OnboardingProgress.self,
                from: JSONEncoder().encode(progress)
            )
            #expect(roundTripped.currentStep == step)
        }
    }

    @Test("meeting permissions do not block dictation step resume")
    func meetingPermissionsDoNotBlockDictationResume() {
        let permissions = OnboardingPermissionSnapshot(
            microphone: true,
            accessibility: true,
            inputMonitoring: true,
            systemAudio: false,
            screenRecording: false
        )

        let step = OnboardingPermissionGate.resumeStep(
            requestedStep: 4,
            permissions: permissions,
            useCase: .dictation,
            permissionsStep: 3,
            dictationTestStep: 4
        )

        #expect(OnboardingPermissionGate.hasRequiredDictationPermissions(permissions))
        #expect(step == 4)
    }

    @Test("missing core permission resumes at permissions step")
    func missingCorePermissionResumesAtPermissionsStep() {
        let permissions = OnboardingPermissionSnapshot(
            microphone: true,
            accessibility: true,
            inputMonitoring: false,
            systemAudio: true,
            screenRecording: true
        )

        let step = OnboardingPermissionGate.resumeStep(
            requestedStep: 4,
            permissions: permissions,
            useCase: .dictation,
            permissionsStep: 3,
            dictationTestStep: 4
        )

        #expect(!OnboardingPermissionGate.hasRequiredDictationPermissions(permissions))
        #expect(step == 3)
    }

    @Test("meetings-only resume requires microphone before leaving permissions step")
    func meetingsOnlyResumeRequiresMicrophone() {
        let permissions = OnboardingPermissionSnapshot(
            microphone: false,
            accessibility: false,
            inputMonitoring: false,
            systemAudio: false,
            screenRecording: false
        )

        let step = OnboardingPermissionGate.resumeStep(
            requestedStep: 5,
            permissions: permissions,
            useCase: .meetings,
            permissionsStep: 3,
            dictationTestStep: 4
        )

        #expect(!OnboardingPermissionGate.hasRequiredPermissions(permissions, for: .meetings))
        #expect(step == 3)
    }

    @Test("meetings-only does not require input monitoring")
    func meetingsOnlyDoesNotRequireInputMonitoring() {
        let permissions = OnboardingPermissionSnapshot(
            microphone: true,
            accessibility: false,
            inputMonitoring: false,
            systemAudio: false,
            screenRecording: false
        )

        let step = OnboardingPermissionGate.resumeStep(
            requestedStep: 5,
            permissions: permissions,
            useCase: .meetings,
            permissionsStep: 3,
            dictationTestStep: 4
        )

        #expect(OnboardingPermissionGate.hasRequiredPermissions(permissions, for: .meetings))
        #expect(step == 5)
    }

    @Test("voice notes require microphone and input monitoring")
    func voiceNotesRequireMicrophoneAndInputMonitoring() {
        let permissions = OnboardingPermissionSnapshot(
            microphone: true,
            accessibility: false,
            inputMonitoring: true,
            systemAudio: false,
            screenRecording: false
        )

        let step = OnboardingPermissionGate.resumeStep(
            requestedStep: 5,
            permissions: permissions,
            useCase: .voiceNotes,
            permissionsStep: 3,
            dictationTestStep: 4
        )

        #expect(OnboardingPermissionGate.hasRequiredVoiceNotesPermissions(permissions))
        #expect(OnboardingPermissionGate.hasRequiredPermissions(permissions, for: .voiceNotes))
        #expect(step == 5)
    }

    @Test("voice notes cannot leave permissions without input monitoring")
    func voiceNotesMissingInputMonitoringResumesAtPermissionsStep() {
        let permissions = OnboardingPermissionSnapshot(
            microphone: true,
            accessibility: false,
            inputMonitoring: false,
            systemAudio: false,
            screenRecording: false
        )

        let step = OnboardingPermissionGate.resumeStep(
            requestedStep: 4,
            permissions: permissions,
            useCase: .voiceNotes,
            permissionsStep: 3,
            dictationTestStep: 4
        )

        #expect(!OnboardingPermissionGate.hasRequiredVoiceNotesPermissions(permissions))
        #expect(step == 3)
    }
}
