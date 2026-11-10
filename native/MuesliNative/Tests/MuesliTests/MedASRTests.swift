import AppKit
import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp
@testable import MuesliCLI

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
        let license = try MedASRTestLicense()
        defer { license.remove() }
        let started = MedASRTestSignal(), release = MedASRTestSignal()
        let count = MedASRTestCounter(), ready = MedASRTestCounter()
        let transcriber = MedASRTranscriber(loader: { _,_ in
            _ = await count.increment()
            return .init(predict: { _ in
                await started.signal()
                await release.wait()
                return []
            }, vocabulary: [:])
        }, license: license.store)
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
        let license = try MedASRTestLicense()
        defer { license.remove() }
        let started = MedASRTestSignal(), release = MedASRTestSignal()
        let transcriber = MedASRTranscriber(loader: { _,_ in
            await started.signal(); await release.wait()
            return .init(predict: { _ in [] }, vocabulary: [:])
        }, license: license.store)
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
        let license = try MedASRTestLicense()
        defer { license.remove() }
        let started = MedASRTestSignal(), joined = MedASRTestSignal(), release = MedASRTestSignal()
        let calls = MedASRTestCounter()
        let transcriber = MedASRTranscriber(loader: { _,_ in
            _ = await calls.increment()
            await started.signal(); await release.wait()
            return .init(predict: { _ in [] }, vocabulary: [:])
        }, license: license.store)
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


/// Synthetic acknowledgements are isolated from the user's real acceptance record.
struct MedASRTestLicense: Sendable {
    let store: MedASRLicense
    let directory: URL
    init(accepted: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = MedASRLicense(recordURL: directory.appendingPathComponent("medasr.json"))
        if accepted { try store.accept() }
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

extension MedASRTests {
    @Test("Full terms and prohibited-use policy are available offline before any model download")
    func completeAgreement() throws {
        let text = try MedASRLicense.agreementText()
        #expect(text.contains("Section 3: DISTRIBUTION AND RESTRICTIONS"))
        #expect(text.contains("Section 4: ADDITIONAL PROVISIONS"))
        #expect(text.contains("Prohibited Use Policy"))
        #expect(text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .contains("without obtaining all rights, authorizations, and consents"))
        #expect(text.contains("incorporated as binding restrictions"))
    }

    @Test("Preparation fails before download or warmup until terms have been accepted")
    func unacceptedPreparation() async throws {
        let license = try MedASRTestLicense(accepted: false)
        defer { license.remove() }
        let calls = MedASRTestCounter()
        let transcriber = MedASRTranscriber(loader: { _,_ in
            _ = await calls.increment()
            return .init(predict: { _ in [] }, vocabulary: [:])
        }, license: license.store)
        await #expect(throws: MedASRLicenseError.self) { try await transcriber.prepare() }
        #expect(await calls.value == 0)
        #expect(!FileManager.default.fileExists(atPath: license.store.recordURL.path))
    }

    @Test("Acceptance is versioned and persists separately from weights")
    func persistedAcceptance() throws {
        let license = try MedASRTestLicense(accepted: false)
        defer { license.remove() }
        #expect(!license.store.isAccepted)
        try license.store.accept()
        let reopened = MedASRLicense(recordURL: license.store.recordURL)
        try reopened.requireAcceptance()
        #expect(reopened.isAccepted)
        var record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: reopened.recordURL)) as? [String: Any])
        record["version"] = "old-version"
        try JSONSerialization.data(withJSONObject: record).write(to: reopened.recordURL)
        #expect(!reopened.isAccepted)
        #expect(throws: MedASRLicenseError.self) { try reopened.requireAcceptance() }
        try Data("invalid".utf8).write(to: reopened.recordURL)
        #expect(!reopened.isAccepted)
    }

    @Test("Reading CLI terms never grants acceptance; only explicit --accept records it")
    func cliAcceptance() throws {
        let license = try MedASRTestLicense(accepted: false)
        defer { license.remove() }
        let read = try ModelTermsCommand.parse(["medasr"])
        #expect(!read.accept)
        var output = ""
        try read.perform(license: license.store, output: { output = $0 })
        #expect(output.contains("Section 3: DISTRIBUTION AND RESTRICTIONS"))
        #expect(!license.store.isAccepted)
        let accept = try ModelTermsCommand.parse(["medasr", "--accept"])
        try accept.perform(license: license.store, output: { output = $0 })
        #expect(license.store.isAccepted)
        #expect(output.contains("MedASR terms accepted."))
        #expect(throws: (any Error).self) { _ = try ModelTermsCommand.parse(["unknown"]) }
    }
}


extension MedASRTests {
    @Test("The complete agreement extends beyond the viewport and can scroll to its end")
    @MainActor
    func termsScrolling() throws {
        let text = try MedASRLicense.agreementText()
        let scroll = MedASRTermsPresentation.scrollView(text: text)
        let document = try #require(scroll.documentView as? NSTextView)
        #expect(document.string == text)
        #expect(!document.isEditable)
        #expect(document.frame.height > scroll.contentSize.height * 2)
        let initial = scroll.contentView.bounds.origin.y
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.frame.height - scroll.contentSize.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.contentView.bounds.origin.y > initial)
        #expect(scroll.contentView.documentVisibleRect.maxY >= document.frame.maxY - 1)
    }
}


extension MedASRTests {
    @Test("Terms presentation returns before a response and Cancel never records acceptance or resumes work")
    @MainActor
    func nonblockingTermsResponse() async throws {
        let fixture = try MedASRTestLicense(accepted: false)
        defer { fixture.remove() }
        var response: (@MainActor (NSApplication.ModalResponse) async -> Void)?
        var resumed = 0
        let present: MedASRTermsPresentation.Presenter = { _, completion in response = completion }
        await MedASRTermsPresentation.request(license: fixture.store, present: present) { resumed += 1 }
        #expect(!fixture.store.isAccepted)
        #expect(resumed == 0)
        let cancel = try #require(response)
        await cancel(.alertSecondButtonReturn)
        #expect(!fixture.store.isAccepted)
        #expect(resumed == 0)
        await MedASRTermsPresentation.request(license: fixture.store, present: present) { resumed += 1 }
        let abort = try #require(response)
        await abort(.abort)
        #expect(!fixture.store.isAccepted)
        #expect(resumed == 0)
        await MedASRTermsPresentation.request(license: fixture.store, present: present) { resumed += 1 }
        let agree = try #require(response)
        await agree(.alertFirstButtonReturn)
        #expect(fixture.store.isAccepted)
        #expect(resumed == 1)
    }
}


extension MedASRTests {
    @Test("Acceptance refresh reads off the main thread, starts closed and observes external changes")
    @MainActor
    func acceptanceSnapshot() async throws {
        let fixture = try MedASRTestLicense(accepted: false)
        defer { fixture.remove() }
        let state = MedASRTermsState()
        #expect(!state.isAccepted)
        await state.refresh {
            #expect(!Thread.isMainThread)
            return fixture.store.isAccepted
        }
        #expect(!state.isAccepted)
        try await Task.detached { try fixture.store.accept() }.value
        await state.refresh { fixture.store.isAccepted }
        #expect(state.isAccepted)
        try await Task.detached { try FileManager.default.removeItem(at: fixture.store.recordURL) }.value
        await state.refresh { fixture.store.isAccepted }
        #expect(!state.isAccepted)
    }

    @Test("A stalled acceptance read leaves the UI actor free and cannot overwrite newer acceptance")
    @MainActor
    func acceptanceRefreshOwnership() async {
        let state = MedASRTermsState()
        let release = DispatchSemaphore(value: 0)
        let entered = AsyncStream<Void>.makeStream()
        let stale = Task {
            await state.refresh {
                entered.continuation.yield(())
                release.wait()
                return false
            }
        }
        for await _ in entered.stream { break }
        // This executes on MainActor while the disk-read substitute is still blocked.
        state.didAccept()
        #expect(state.isAccepted)
        release.signal()
        await stale.value
        #expect(state.isAccepted)

        let cancelled = Task {
            await state.refresh { false }
        }
        cancelled.cancel()
        await cancelled.value
        #expect(state.isAccepted)
    }
}
