import Testing
@testable import MuesliNativeApp

@Suite("SuggestionAnalysisCoalescer")
struct SuggestionAnalysisCoalescerTests {

    /// Drive the coalescer the way the controller does: start a run when a trigger
    /// says to, then loop while `onRunFinished` asks for another pass. Returns the
    /// number of analysis passes that would actually run.
    private func runLoop(_ coalescer: inout SuggestionAnalysisCoalescer,
                         triggersDuringEachPass: [Int]) -> Int {
        guard coalescer.onTrigger() else { return 0 }
        var passes = 0
        var remaining = triggersDuringEachPass
        repeat {
            passes += 1
            // Simulate triggers that arrive while this pass is running.
            if !remaining.isEmpty {
                for _ in 0..<remaining.removeFirst() {
                    _ = coalescer.onTrigger()
                }
            }
        } while coalescer.onRunFinished()
        return passes
    }

    @Test("a single trigger runs exactly one pass")
    func singleTrigger() {
        var coalescer = SuggestionAnalysisCoalescer()
        let passes = runLoop(&coalescer, triggersDuringEachPass: [0])
        #expect(passes == 1)
        #expect(coalescer.isRunning == false)
    }

    @Test("the first trigger starts a run; it is the only one that returns true")
    func firstTriggerStartsRun() {
        var coalescer = SuggestionAnalysisCoalescer()
        #expect(coalescer.onTrigger() == true)
        #expect(coalescer.isRunning == true)
        // Further triggers while running do not start a second loop.
        #expect(coalescer.onTrigger() == false)
        #expect(coalescer.onTrigger() == false)
    }

    @Test("a burst of triggers during one pass collapses into exactly one rerun")
    func burstCollapsesToOneRerun() {
        var coalescer = SuggestionAnalysisCoalescer()
        // Five triggers arrive while the first pass runs -> one rerun, two passes.
        let passes = runLoop(&coalescer, triggersDuringEachPass: [5])
        #expect(passes == 2)
        #expect(coalescer.isRunning == false)
    }

    @Test("triggers arriving during the rerun queue one more pass")
    func triggersDuringRerunChain() {
        var coalescer = SuggestionAnalysisCoalescer()
        // Pass 1 gets 3 triggers -> rerun. Pass 2 (the rerun) gets 2 more -> another
        // rerun. Pass 3 gets none -> stop. Three passes total.
        let passes = runLoop(&coalescer, triggersDuringEachPass: [3, 2, 0])
        #expect(passes == 3)
        #expect(coalescer.isRunning == false)
    }

    @Test("after a run finishes, a fresh trigger starts a new run")
    func newRunAfterCompletion() {
        var coalescer = SuggestionAnalysisCoalescer()
        let first = runLoop(&coalescer, triggersDuringEachPass: [0])
        #expect(first == 1)
        #expect(coalescer.isRunning == false)
        // A later, independent trigger must be able to start again.
        let second = runLoop(&coalescer, triggersDuringEachPass: [1])
        #expect(second == 2)
        #expect(coalescer.isRunning == false)
    }

    @Test("a rerun request does not survive past the run that consumed it")
    func rerunRequestDoesNotLeak() {
        var coalescer = SuggestionAnalysisCoalescer()
        // One trigger during pass 1 schedules the rerun (pass 2). No triggers during
        // pass 2, so the loop must stop at two passes, not spin forever.
        let passes = runLoop(&coalescer, triggersDuringEachPass: [1, 0])
        #expect(passes == 2)
        #expect(coalescer.isRunning == false)
    }
}
