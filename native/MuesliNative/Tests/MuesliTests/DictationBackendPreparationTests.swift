import Testing
@testable import MuesliNativeApp

@Suite("Dictation backend preparation ownership")
struct DictationBackendPreparationTests {
    @Test("A new local or hosted selection cancels the previous preparation task", arguments: [true, false])
    func switchingCancelsPreparation(_ hosted: Bool) async {
        var state = DictationBackendPreparationState()
        let first = state.begin(isHosted: false)
        let task = Task<Void, Never> { }
        state.track(task, for: first)
        #expect(!task.isCancelled)
        let next = state.begin(isHosted: hosted)
        #expect(task.isCancelled)
        #expect(state.owns(next))
        let finished = state.finish(first, succeeded: true)
        #expect(!finished)
        await task.value
    }

    @Test("An obsolete selection cannot attach work to the newer selection")
    func staleTaskAttachmentIsCancelled() async {
        var state = DictationBackendPreparationState()
        let first = state.begin(isHosted: false)
        let next = state.begin(isHosted: false)
        let stale = Task<Void, Never> { }
        state.track(stale, for: first)
        #expect(stale.isCancelled)
        #expect(state.owns(next))
        await stale.value
    }

    @Test("Late success and failure cannot finish a newer warmup", arguments: [true, false])
    func supersededCompletion(succeeded: Bool) {
        var state = DictationBackendPreparationState()
        let first = state.begin(isHosted: false)
        let second = state.begin(isHosted: false)

        // A false completion result also forbids hiding the current spinner.
        let finished1 = state.finish(first, succeeded: succeeded)
        #expect(!finished1)
        #expect(state.readiness == .preparing)
        #expect(state.owns(second))
        let finished2 = state.finish(second, succeeded: true)
        #expect(finished2)
        #expect(state.readiness == .ready)
    }

    @Test("Returning to the same model does not revive its old preparation")
    func repeatedSelection() {
        var state = DictationBackendPreparationState()
        let firstA = state.begin(isHosted: false)
        let modelB = state.begin(isHosted: false)
        let secondA = state.begin(isHosted: false)

        let finished3 = state.finish(firstA, succeeded: true)
        #expect(!finished3)
        let finished4 = state.finish(modelB, succeeded: false)
        #expect(!finished4)
        #expect(state.readiness == .preparing)
        let finished5 = state.finish(secondA, succeeded: false)
        #expect(finished5)
        #expect(state.readiness == .failed)
    }

    @Test("Hosted selection invalidates local warmup immediately", arguments: [true, false])
    func hostedSelection(succeeded: Bool) {
        var state = DictationBackendPreparationState()
        let local = state.begin(isHosted: false)
        _ = state.begin(isHosted: true)

        #expect(state.readiness == .ready)
        #expect(!state.owns(local))
        let finished6 = state.finish(local, succeeded: succeeded)
        #expect(!finished6)
        #expect(state.readiness == .ready)

        let nextLocal = state.begin(isHosted: false)
        #expect(state.readiness == .preparing)
        let finished7 = state.finish(nextLocal, succeeded: true)
        #expect(finished7)
        #expect(state.readiness == .ready)
    }
}
