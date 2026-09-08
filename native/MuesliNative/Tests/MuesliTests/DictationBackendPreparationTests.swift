import Testing
@testable import MuesliNativeApp

@Suite("Dictation backend preparation ownership")
struct DictationBackendPreparationTests {
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
