import Testing
@testable import MuesliNativeApp

@Suite("Interactive audio session ownership")
struct InteractiveAudioSessionOwnershipTests {
    @Test("idle ownership allows either feature to start")
    func idleAllowsEitherOwner() {
        let ownership = InteractiveAudioSessionOwnership(
            dictationIsActive: false,
            computerUseIsActive: false
        )

        #expect(ownership.canStart(.dictation))
        #expect(ownership.canStart(.computerUse))
        #expect(ownership.canStart(.quil))
        #expect(!ownership.shouldIgnoreCleanup(for: .dictation))
        #expect(!ownership.shouldIgnoreCleanup(for: .computerUse))
    }

    @Test("Quill ownership rejects dictation and computer use")
    func quilWinsOverOtherInteractiveAudio() {
        let ownership = InteractiveAudioSessionOwnership(
            dictationIsActive: false,
            computerUseIsActive: false,
            quilIsActive: true
        )

        #expect(!ownership.canStart(.dictation))
        #expect(!ownership.canStart(.computerUse))
        #expect(ownership.canStart(.quil))
        #expect(ownership.shouldIgnoreCleanup(for: .dictation))
        #expect(ownership.shouldIgnoreCleanup(for: .computerUse))
        #expect(!ownership.shouldIgnoreCleanup(for: .quil))
    }

    @Test("dictation ownership rejects computer use start and cleanup")
    func dictationWinsOverComputerUse() {
        let ownership = InteractiveAudioSessionOwnership(
            dictationIsActive: true,
            computerUseIsActive: false
        )

        #expect(ownership.canStart(.dictation))
        #expect(!ownership.canStart(.computerUse))
        #expect(ownership.shouldIgnoreCleanup(for: .computerUse))
        #expect(!ownership.shouldIgnoreCleanup(for: .dictation))
    }

    @Test("computer use ownership rejects dictation start and cleanup")
    func computerUseWinsOverDictation() {
        let ownership = InteractiveAudioSessionOwnership(
            dictationIsActive: false,
            computerUseIsActive: true
        )

        #expect(!ownership.canStart(.dictation))
        #expect(ownership.canStart(.computerUse))
        #expect(ownership.shouldIgnoreCleanup(for: .dictation))
        #expect(!ownership.shouldIgnoreCleanup(for: .computerUse))
    }

    @Test("an existing overlap still permits both owners to clean up")
    func existingOverlapCanCleanUp() {
        let ownership = InteractiveAudioSessionOwnership(
            dictationIsActive: true,
            computerUseIsActive: true
        )

        #expect(!ownership.canStart(.dictation))
        #expect(!ownership.canStart(.computerUse))
        #expect(!ownership.shouldIgnoreCleanup(for: .dictation))
        #expect(!ownership.shouldIgnoreCleanup(for: .computerUse))
    }
}
