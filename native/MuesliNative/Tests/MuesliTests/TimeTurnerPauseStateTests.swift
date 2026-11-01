import Testing
@testable import MuesliNativeApp

@Suite("Time Turner automatic resume")
struct TimeTurnerPauseStateTests {
    @Test func resumesAfterWakeOrUnlock() {
        var state = TimeTurnerPauseState()
        state.sleeping = true
        #expect(state.isPaused)
        state.sleeping = false
        #expect(!state.isPaused)
        state.screenLocked = true
        #expect(state.isPaused)
        state.screenLocked = false
        #expect(!state.isPaused)
    }

    @Test func overlappingSleepAndLockRequireBothToClear() {
        for wakeFirst in [true, false] {
            var state = TimeTurnerPauseState(sleeping: true, screenLocked: true)
            if wakeFirst { state.sleeping = false } else { state.screenLocked = false }
            #expect(state.isPaused)
            state.sleeping = false
            state.screenLocked = false
            #expect(!state.isPaused)
        }
    }

    @Test func manualPauseSurvivesSystemResume() {
        var state = TimeTurnerPauseState(userPaused: true, sleeping: true, screenLocked: true)
        state.sleeping = false
        state.screenLocked = false
        #expect(state.isPaused)
        #expect(state.userPaused)
    }

    @Test func manualResumeCannotBypassSystemSuspension() {
        var state = TimeTurnerPauseState(userPaused: true, screenLocked: true)
        state.userPaused = false
        #expect(state.isPaused)
        state.screenLocked = false
        #expect(!state.isPaused)
    }
}
