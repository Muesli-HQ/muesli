import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Telegram scoped synthetic recognition")
struct TelegramCallDetectionRecognitionTests {
    private typealias F = TelegramCallDetectionFixtures

    @Test func connectedRequiresControlsAndExplicitStateOnOneSurface() {
        let surface = F.surface()
        #expect(TelegramCallDetectionClassifier.classify([surface]) == .surface(surface))
        #expect(TelegramCallDetectionClassifier.classify([F.surface(controls: [.endCall])]) == .unavailable(.unsupported))
        #expect(TelegramCallDetectionClassifier.classify([F.surface(states: [.unknown])]) == .unavailable(.unsupported))
    }

    @Test func idleVoiceNotesSettingsAndHistoryNeverClaimConnected() {
        for scope in [TelegramCallDetectionScope.chat, .voiceMessageRecording, .voiceMessagePlayback, .settings, .callHistory] {
            #expect(TelegramCallDetectionClassifier.classify([F.surface(scope: scope)]) == .unavailable(.unsupported))
        }
        #expect(TelegramCallDetectionClassifier.classify([]) == .unavailable(.unsupported))
        #expect(TelegramCallDetectionClassifier.classify([F.surface(profile: .unverifiedLive)]) == .unavailable(.unsupported))
    }

    @Test func conflictingStatesAndPrejoinControlsFailClosed() {
        #expect(TelegramCallDetectionClassifier.classify([F.surface(states: [.connected, .ended])]) == .unavailable(.ambiguous))
        #expect(TelegramCallDetectionClassifier.classify([F.surface(controls: [.endCall, .mute, .unmute])]) == .unavailable(.ambiguous))
        for control in [TelegramCallDetectionControl.acceptCall, .joinCall, .redialCall, .declineCall] {
            #expect(TelegramCallDetectionClassifier.classify([F.surface(controls: [.endCall, .mute, control])]) == .unavailable(.unsupported))
        }
    }

    @Test func multipleOrDuplicateCallSurfacesAndSplitEvidenceAreAmbiguous() {
        #expect(TelegramCallDetectionClassifier.classify([F.surface(), F.surface()]) == .unavailable(.ambiguous))
        let second = F.changedSource(surface: "second-window")
        #expect(TelegramCallDetectionClassifier.classify([
            F.surface(controls: [.endCall]), F.surface(source: second, controls: [.mute])
        ]) == .unavailable(.ambiguous))
    }

    @Test func completeSourceIsPinnedAndUnknownBundlesAreRejected() {
        let mismatches = [F.changedSource(pid: 43), F.changedSource(launch: "new-launch"),
                          F.changedSource(surface: "different-window"), F.changedSource(origin: "https://example.invalid")]
        for source in mismatches {
            #expect(TelegramCallDetectionClassifier.classify([F.surface(observedSource: source)]) == .unavailable(.sourceMismatch))
        }
        for source in [F.changedSource(bundleID: "ru.keepcoder.Telegram.fake"), F.changedSource(pid: 0),
                       F.changedSource(launch: ""), F.changedSource(surface: ""), F.changedSource(origin: "https://example.invalid")] {
            #expect(TelegramCallDetectionClassifier.classify([F.surface(source: source)]) == .unavailable(.sourceMismatch))
        }
    }

    @Test func ringingPrejoinAndEndedRemainNonConnected() {
        for phase in [CallDetectionPhase.ringing, .connecting, .ended] {
            let surface = F.surface(states: [phase])
            #expect(TelegramCallDetectionClassifier.classify([surface]) == .surface(surface))
        }
    }

    @Test func inputCapsAndMissingGenerationFailClosed() {
        #expect(TelegramCallDetectionClassifier.classify(Array(repeating: F.surface(), count: 9)) == .unavailable(.unsupported))
        #expect(TelegramCallDetectionClassifier.classify([F.surface(generation: "")]) == .unavailable(.unsupported))
        #expect(TelegramCallDetectionClassifier.classify([F.surface(roster: .partial([""]))]) == .unavailable(.unsupported))
        #expect(TelegramCallDetectionClassifier.classify([F.surface(roster: .complete(Set((0..<129).map { "opaque-\($0)" })))]) == .unavailable(.unsupported))
    }

    @Test func generatedControlSubsetsCannotBypassConnectedProof() {
        // Removing either proof control, or accepting prejoin controls, breaks this invariant.
        let controls: [TelegramCallDetectionControl] = [.endCall, .mute, .unmute, .acceptCall, .joinCall, .redialCall, .declineCall]
        for bits in 0..<(1 << controls.count) {
            let selected = Set(controls.enumerated().compactMap { index, control in
                bits & (1 << index) == 0 ? nil : control
            })
            let result = TelegramCallDetectionClassifier.classify([F.surface(controls: selected)])
            let accepted = selected == [.endCall, .mute] || selected == [.endCall, .unmute]
            if case .surface = result { #expect(accepted) } else { #expect(!accepted) }
        }
    }
}
