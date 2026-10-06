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
            hotkey: HotkeyConfig(keyCode: 55, label: "Left Cmd"),
            modelDownloadProgress: 0.42,
            modelDownloadStatus: "189 MB of 450 MB"
        )

        let data = try JSONEncoder().encode(progress)
        let decoded = try JSONDecoder().decode(OnboardingProgress.self, from: data)

        #expect(decoded.modelDownloadProgress == 0.42)
        #expect(decoded.modelDownloadStatus == "189 MB of 450 MB")
    }

    @Test("combination dictation shortcut survives onboarding progress round trip")
    func combinationDictationShortcutRoundTrips() throws {
        let chord = HotkeyConfig.combination(modifiers: [.control, .option], keyCode: 49)
        let progress = OnboardingProgress(
            currentStep: OnboardingFlow.dictationTestStep,
            userName: "Test User",
            selectedBackendKey: "fluidaudio",
            selectedModelKey: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
            hotkey: chord
        )

        let decoded = try JSONDecoder().decode(OnboardingProgress.self, from: JSONEncoder().encode(progress))

        #expect(decoded.hotkey == chord)
        #expect(decoded.hotkey.label == "⌃⌥Space")
    }

    @Test("legacy and invalid onboarding shortcuts resume with a live hotkey")
    func legacyAndInvalidOnboardingShortcuts() throws {
        let legacy = try JSONDecoder().decode(OnboardingProgress.self, from: Data("""
        {
          "schemaVersion": 4,
          "currentStep": 2,
          "userName": "Test User",
          "selectedBackendKey": "fluidaudio",
          "selectedModelKey": "FluidInference/parakeet-tdt-0.6b-v3-coreml",
          "hotkeyKeyCode": 55,
          "hotkeyLabel": "Left Cmd"
        }
        """.utf8))
        #expect(legacy.hotkey == HotkeyConfig(keyCode: 55, label: "Left Cmd"))

        // A combination saved without its key code would otherwise register nothing.
        let truncated = try JSONDecoder().decode(OnboardingProgress.self, from: Data("""
        {
          "schemaVersion": 4,
          "currentStep": 2,
          "userName": "Test User",
          "selectedBackendKey": "fluidaudio",
          "selectedModelKey": "FluidInference/parakeet-tdt-0.6b-v3-coreml",
          "hotkeyKeyCode": 65535,
          "hotkeyLabel": "⌘⇧D",
          "hotkeyCombinationModifiers": 1179648
        }
        """.utf8))
        #expect(truncated.hotkey == .default)
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
                hotkey: HotkeyConfig(keyCode: 55, label: "Left Cmd")
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

    @Test("meetings-only requires system audio but not input monitoring")
    func meetingsOnlyRequiresSystemAudioButNotInputMonitoring() {
        let permissions = OnboardingPermissionSnapshot(
            microphone: true,
            accessibility: false,
            inputMonitoring: false,
            systemAudio: true,
            screenRecording: false
        )

        let step = OnboardingPermissionGate.resumeStep(
            requestedStep: 5,
            permissions: permissions,
            useCase: .meetings,
            permissionsStep: 3,
            dictationTestStep: 4
        )

        #expect(OnboardingPermissionGate.hasRequiredMeetingPermissions(permissions))
        #expect(OnboardingPermissionGate.hasRequiredPermissions(permissions, for: .meetings))
        #expect(step == 5)
    }

    @Test("meetings-only cannot leave permissions without system audio")
    func meetingsOnlyMissingSystemAudioResumesAtPermissionsStep() {
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

        #expect(!OnboardingPermissionGate.hasRequiredMeetingPermissions(permissions))
        #expect(!OnboardingPermissionGate.hasRequiredPermissions(permissions, for: .meetings))
        #expect(OnboardingPermissionGate.hasRequiredStartupPermissions(permissions, for: .meetings))
        #expect(step == 3)
    }

    @Test("ScreenCaptureKit meetings require Screen Recording instead of the CoreAudio permission")
    func screenCaptureKitMeetingsRequireScreenRecording() {
        let permissions = OnboardingPermissionSnapshot(
            microphone: true,
            accessibility: false,
            inputMonitoring: false,
            systemAudio: false,
            screenRecording: true
        )

        #expect(OnboardingPermissionGate.hasRequiredMeetingPermissions(
            permissions,
            useCoreAudioTap: false
        ))
        #expect(OnboardingPermissionGate.hasRequiredPermissions(
            permissions,
            for: .meetings,
            useCoreAudioTap: false
        ))
        #expect(!OnboardingPermissionGate.hasRequiredPermissions(permissions, for: .meetings))
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

    @Test("multi-select permission requirements use the strictest capability union")
    func multiSelectPermissionUnion() {
        let voiceAndMeetings = OnboardingPermissionSnapshot(
            microphone: true,
            accessibility: false,
            inputMonitoring: true,
            systemAudio: true,
            screenRecording: false
        )
        #expect(OnboardingPermissionGate.hasRequiredPermissions(voiceAndMeetings, for: .voiceNotesAndMeetings))

        var voiceAndMeetingsWithoutSystemAudio = voiceAndMeetings
        voiceAndMeetingsWithoutSystemAudio.systemAudio = false
        #expect(!OnboardingPermissionGate.hasRequiredPermissions(
            voiceAndMeetingsWithoutSystemAudio,
            for: .voiceNotesAndMeetings
        ))

        let everythingWithoutAccessibility = OnboardingPermissionSnapshot(
            microphone: true,
            accessibility: false,
            inputMonitoring: true,
            systemAudio: true,
            screenRecording: false
        )
        #expect(!OnboardingPermissionGate.hasRequiredPermissions(everythingWithoutAccessibility, for: .everything))

        var everythingGranted = everythingWithoutAccessibility
        everythingGranted.accessibility = true
        #expect(OnboardingPermissionGate.hasRequiredPermissions(everythingGranted, for: .everything))
    }
}
