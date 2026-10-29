import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("MedASR")
struct MedASRTests {
    @Test("Catalog and download plan identify the pinned English CTC model")
    func catalogAndPlan() {
        let plan = MedASRModel.plan()
        #expect(BackendOption.all.contains(.medASR))
        #expect(!BackendOption.onboarding.contains(.medASR))
        #expect(BackendOption.medASR.backend == "medasr")
        #expect(BackendOption.medASR.description.contains("English"))
        #expect(BackendOption.medASR.description.contains("Google"))
        #expect(plan.revision == "07d490538e4c77141a68767a7dd5efe946ad5f15")
        #expect(plan.requiredArtifactAlternatives.contains(["MedASR.mlpackage/Data/com.apple.CoreML/weights/weight.bin"]))
        #expect(plan.requiredArtifactAlternatives.contains(["LICENSE"]))
        #expect(plan.requiredArtifactAlternatives.contains(["Notice"]))
    }

    @Test("Valid lengths account for both unpadded subsampling convolutions")
    func validLengths() {
        #expect(MedASRModel.featureLength(samples: 320_000) == 1998)
        #expect(MedASRModel.encodedLength(features: 1998) == 497)
        #expect(MedASRModel.encodedLength(features: 13) == 1)
        #expect(MedASRModel.encodedLength(features: 12) == 0)
        #expect(MedASRModel.featureLength(samples: 0) == 0)
    }

    @Test("Exact full final windows retain their tail instead of assuming another chunk")
    func exactWindow() {
        var windows = MedASRAudioWindows()
        windows.append([Float](repeating: 0, count: 320_000))
        #expect(windows.next(final: false) == nil)
        let last = windows.next(final: true)
        #expect(last?.leftContext == 0)
        #expect(last?.rightContext == 0)
        #expect(last?.retainedFrames == 0..<497)
        #expect(windows.next(final: true) == nil)
    }

    @Test("Overlap trims form a continuous frame stream with no duplicate or missing boundary frame")
    func overlapBoundaries() throws {
        var windows = MedASRAudioWindows()
        windows.append((0..<576_000).map(Float.init)) // 36 seconds
        let firstValue = windows.next(final: false)
        let first = try #require(firstValue)
        #expect(first.retainedFrames == 0..<449)
        #expect(windows.next(final: false) == nil)
        let secondValue = windows.next(final: true)
        let second = try #require(secondValue)
        #expect(second.samples.first == 256_000)
        #expect(second.retainedFrames == 49..<497)
        let positions = Array(first.retainedFrames) + second.retainedFrames.map { $0 + 400 }
        #expect(positions == Array(0..<897))
        #expect(windows.pending.isEmpty)
    }

    @Test("A short tail retains new audio and the trailing context from the previous window")
    func shortTail() throws {
        var windows = MedASRAudioWindows()
        windows.append([Float](repeating: 0.1, count: 320_160))
        let firstValue = windows.next(final: false)
        _ = try #require(firstValue)
        let tailValue = windows.next(final: true)
        let tail = try #require(tailValue)
        #expect(tail.samples.count == 64_160)
        #expect(tail.rightContext == 0)
        #expect(!tail.retainedFrames.isEmpty)
    }

    @Test("CTC repeated tokens and blank resets are preserved across chunk boundaries")
    func ctcBoundary() {
        var result = MedASRCTCAccumulator()
        result.append([0,4,4])
        result.append([4,0,4,6,6,0])
        #expect(result.tokenIDs == [4,4,6])
    }

    @Test("Medical formatting controls render punctuation without rewriting clinical content")
    func formatting() {
        #expect(MedASRFormatting.render("CT chest {period} No PE {period}") == "CT chest. No PE.")
        #expect(MedASRFormatting.render("Dose {colon} 2.5 mg {new paragraph} Plan {colon} review") == "Dose: 2.5 mg\n\nPlan: review")
        #expect(MedASRFormatting.render("[INDICATION] {unknown} 54-year-old") == "[INDICATION] {unknown} 54-year-old")
    }
}

actor MedASRTestSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void,Never>] = []
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

actor MedASRTestCounter {
    var value = 0
    func increment() -> Int { value += 1; return value }
}

@Suite("MedASR preparation")
struct MedASRPreparationTests {
    @Test("Readiness waits for warmup and cached preparation does not repeat it")
    func warmup() async throws {
        let started = MedASRTestSignal(), release = MedASRTestSignal()
        let count = MedASRTestCounter(), ready = MedASRTestCounter()
        let transcriber = MedASRTranscriber(loader: { _,_ in
            _ = await count.increment()
            return .init(predict: { _ in
                await started.signal()
                await release.wait()
                return []
            }, vocabulary: [:])
        })
        let loading = Task {
            try await transcriber.prepare(progressSnapshot: { snapshot in
                if snapshot.phase == .ready { Task { _ = await ready.increment() } }
            })
        }
        await started.wait()
        #expect(await ready.value == 0)
        await release.signal()
        try await loading.value
        try await transcriber.prepare()
        #expect(await count.value == 1)
        await transcriber.shutdown()
    }

    @Test("An uncooperative load completing after shutdown cannot publish readiness")
    func shutdownDuringLoad() async throws {
        let started = MedASRTestSignal(), release = MedASRTestSignal()
        let transcriber = MedASRTranscriber(loader: { _,_ in
            await started.signal(); await release.wait()
            return .init(predict: { _ in [] }, vocabulary: [:])
        })
        let loading = Task { try await transcriber.prepare() }
        await started.wait()
        await transcriber.shutdown()
        await release.signal()
        await #expect(throws: CancellationError.self) { try await loading.value }
        await #expect(throws: MedASRError.self) {
            _ = try await transcriber.transcribe(wavURL: URL(fileURLWithPath: "/not-opened.wav"))
        }
    }

    @Test("Cancelling one same-model waiter preserves the other's preparation")
    func sharedPreparation() async throws {
        let started = MedASRTestSignal(), joined = MedASRTestSignal(), release = MedASRTestSignal()
        let calls = MedASRTestCounter()
        let transcriber = MedASRTranscriber(loader: { _,_ in
            _ = await calls.increment()
            await started.signal(); await release.wait()
            return .init(predict: { _ in [] }, vocabulary: [:])
        })
        let first = Task { try await transcriber.prepare() }
        await started.wait()
        let second = Task {
            try await transcriber.prepare(progressSnapshot: { _ in Task { await joined.signal() } })
        }
        await joined.wait()
        first.cancel()
        await release.signal()
        await #expect(throws: CancellationError.self) { try await first.value }
        try await second.value
        #expect(await calls.value == 1)
        await transcriber.shutdown()
    }
}
