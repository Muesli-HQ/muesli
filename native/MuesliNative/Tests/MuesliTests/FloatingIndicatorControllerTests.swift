import Testing
import AppKit
@testable import MuesliNativeApp

@Suite("Voice orb motion")
struct VoiceOrbMotionTests {
    @Test("silence and loud input are clamped to the supported visual range")
    func normalizedLevelIsClamped() {
        #expect(VoiceOrbMotion.normalizedLevel(fromDecibels: -160) == 0)
        #expect(VoiceOrbMotion.normalizedLevel(fromDecibels: -62) == 0)
        #expect(VoiceOrbMotion.normalizedLevel(fromDecibels: -22) == 1)
        #expect(VoiceOrbMotion.normalizedLevel(fromDecibels: 0) == 1)
    }

    @Test("voice levels rise promptly and settle gently")
    func smoothingUsesAsymmetricResponse() {
        let rising = VoiceOrbMotion.smoothedLevel(current: 0, target: 1)
        let falling = VoiceOrbMotion.smoothedLevel(current: 1, target: 0)

        #expect(abs(rising - 0.36) < 0.0001)
        #expect(abs(falling - 0.86) < 0.0001)
    }

    @Test("speech motion remains deliberately compact")
    func scaleRangeIsSubtle() {
        let silent = VoiceOrbMotion.scales(for: 0)
        let loud = VoiceOrbMotion.scales(for: 1)

        #expect(abs(silent.core - 1) < 0.0001)
        #expect(abs(loud.core - 1.12) < 0.0001)
        #expect(abs(silent.corona - 0.96) < 0.0001)
        #expect(abs(loud.corona - 1.14) < 0.0001)
    }
}

@Suite("Floating dictation indicator")
struct FloatingIndicatorControllerTests {
    @MainActor
    @Test("standard dictation keeps one orb through every visible phase")
    func standardDictationUsesOrbForEveryPhase() {
        let configStore = ConfigStore()
        let config = configStore.load()
        let indicator = FloatingIndicatorController(configStore: configStore)

        indicator.setState(.idle, config: config)
        #expect(indicator.currentFrame?.size == NSSize(width: 56, height: 56))

        indicator.setDictationOrbPresentation(.preparing)
        indicator.setState(.preparing, config: config)
        #expect(indicator.currentFrame?.size == NSSize(width: 56, height: 56))

        indicator.setDictationOrbPresentation(.listening)
        indicator.setState(.recording, config: config)
        #expect(indicator.currentFrame?.size == NSSize(width: 56, height: 56))

        indicator.setDictationOrbPresentation(.transcribing)
        indicator.setState(.transcribing, config: config)
        #expect(indicator.currentFrame?.size == NSSize(width: 56, height: 56))
        indicator.close()
    }

    @MainActor
    @Test("inactive workflows retain the preparing waveform frame")
    func inactivePresentationDoesNotUseDictationOrb() {
        let configStore = ConfigStore()
        let config = configStore.load()
        let indicator = FloatingIndicatorController(configStore: configStore)
        indicator.setDictationOrbPresentation(.inactive)

        indicator.setState(.preparing, config: config)

        #expect(indicator.currentFrame?.size == NSSize(width: 76, height: 22))
        indicator.close()
    }

    @MainActor
    @Test("orb click stops dictation while Option-click cancels it")
    func dictationOrbControlsAreNotSplitByPosition() {
        let configStore = ConfigStore()
        let config = configStore.load()
        let indicator = FloatingIndicatorController(configStore: configStore)
        var stopCount = 0
        var cancelCount = 0
        indicator.onStopToggleDictation = { stopCount += 1 }
        indicator.onCancelToggleDictation = { cancelCount += 1 }

        indicator.setState(.idle, config: config)
        indicator.setState(.recording, config: config)
        indicator.handleClick(atX: 1)
        indicator.handleOptionClick()
        indicator.close()

        #expect(stopCount == 1)
        #expect(cancelCount == 1)
    }
}
