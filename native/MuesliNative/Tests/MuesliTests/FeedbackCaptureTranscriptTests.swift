import AVFoundation
import FluidAudio
import WhisperKit
import Speech
import CoreMedia
import Foundation
import SQLite3
import Testing
@testable import MuesliCore
@testable import MuesliNativeApp

@Suite("Scrawl narration")
struct FeedbackCaptureTranscriptTests {
    @Test func whisperKeepsMeasuredWordsAndSegments() {
        let segment = TranscriptionSegment(start: 1, end: 2, text: "open this", words: [
            .init(word: " open", tokens: [1], start: 1, end: 1.4, probability: 1),
            .init(word: " this", tokens: [2], start: 1.5, end: 2, probability: 1)])
        let timing = WhisperKitTranscriber.captureTiming([segment])
        #expect(timing.words.map(\.text) == ["open", "this"])
        #expect(timing.words.first?.start == 1)
        #expect(timing.words.last?.end == 2)
        #expect(timing.segments.first?.text == "open this")
    }

    @Test func appleUsesAttributedAudioRanges() throws {
        guard #available(macOS 26, *) else { return }
        var first = AttributedString("open ")
        first.audioTimeRange = CMTimeRange(start: CMTime(seconds: 0.1, preferredTimescale: 1000),
            end: CMTime(seconds: 0.4, preferredTimescale: 1000))
        var second = AttributedString("this")
        second.audioTimeRange = CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 1000),
            end: CMTime(seconds: 0.9, preferredTimescale: 1000))
        let words = AppleSpeechAnalyzerTranscriber.captureWords(first + second)
        #expect(words.map(\.text) == ["open", "this"])
        #expect(words.first?.start == 0.1)
        #expect(words.last?.end == 0.9)
        #expect(AppleSpeechAnalyzerTranscriber.captureWords(AttributedString("untimed")).isEmpty)
    }

    @Test func characterWeightsPreserveOrderAndBounds() {
        let words = FeedbackCaptureTranscript.estimatedWords("a long word", t0: 7000, t1: 7900)
        #expect(words.map(\.text) == ["a", "long", "word"])
        #expect(words.map(\.t0) == [7000, 7100, 7500])
        #expect(words.map(\.t1) == [7100, 7500, 7900])
        #expect(FeedbackCaptureTranscript.estimatedWords(" \n ", t0: 0, t1: 1).isEmpty)
    }

    @Test func quietCutSearchKeepsSilenceAndTail() throws {
        let rate = 16_000
        var samples = [Float](repeating: 0.4, count: rate * 8)
        samples.replaceSubrange(120_000..<120_800, with: repeatElement(Float(0), count: 800))
        #expect(FeedbackCaptureTranscript.quietCut(samples: samples, sampleRate: Double(rate)) == 120_400)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("feedback-windows-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let all = samples + [Float](repeating: 0, count: rate * 9 + 17)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1))
        do {
            let writer = try AVAudioFile(forWriting: url, settings: format.settings)
            let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(all.count)))
            pcm.frameLength = pcm.frameCapacity
            for i in all.indices { pcm.floatChannelData![0][i] = all[i] }
            try writer.write(from: pcm)
        }
        let reader = try RecordingAudioWindowReader(url: url, seconds: 8, overlapSeconds: 0, quietCuts: true)
        defer { reader.close() }
        var offset = 0
        while let window = try reader.next() {
            #expect(Int((window.start * Double(rate)).rounded()) == offset)
            #expect(window.end - window.start <= 8)
            let file = try AVAudioFile(forReading: window.url)
            let pcm = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            while file.framePosition < file.length {
                try file.read(into: pcm)
                let count = Int(pcm.frameLength)
                try #require(count > 0)
                #expect((0..<count).allSatisfy { pcm.floatChannelData![0][$0] == all[offset + $0] })
                offset += count
            }
        }
        #expect(offset == all.count)
    }

    @Test @MainActor func foregroundDeferralDoesNotExhaustDeadline() async throws {
        let activity = CaptureForegroundActivity()
        let coordinator = TranscriptionCoordinator(foregroundActivity: { activity.busy })
        let url = try captureFixtureAudio(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task {
            await FeedbackCaptureTranscriptionJob().run(timeout: .milliseconds(500)) {
                try await coordinator.transcribeFeedbackCapture(at: url, preferred: nil,
                    config: AppConfig(), installed: [.parakeetUnified]) { _, _, _ in
                    SpeechTranscriptionResult(text: "resumed", segments: [])
                }
            }
        }
        try await Task.sleep(for: .milliseconds(1500))
        activity.busy = false
        #expect(await task.value.text == "resumed")
    }

    @Test func decoderTailIsPaddedWithoutExtendingRealClock() async throws {
        let url = try captureFixtureAudio(seconds: 8.05)
        // Put the quiet cut near eight seconds so the real final source window is only 75 ms.
        var samples = [Float](repeating: 0.4, count: 128_800)
        samples.replaceSubrange(127_200..<128_000, with: repeatElement(Float(0), count: 800))
        try WavWriter.writeWAV(samples: samples, to: url)
        let padded = CaptureCallCounter()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await TranscriptionCoordinator().transcribeFeedbackCapture(at: url,
            preferred: nil, config: AppConfig(), installed: [.parakeetUnified]) { url, _, _ in
                let file = try AVAudioFile(forReading: url)
                let duration = Double(file.length) / file.processingFormat.sampleRate
                #expect(duration >= 0.3, "Pinned FluidAudio rejects decoder inputs below 300 ms")
                if duration < 1 { #expect(duration == 0.3); await padded.increment() }
                return SpeechTranscriptionResult(text: "tail", segments: [])
            }
        #expect(result.words.count == 2)
        #expect(await padded.count == 1)
        #expect(result.words.last?.t0 == 7975)
        #expect(result.words.last?.t1 == 8050)
        #expect(result.words.last!.t1 - result.words.last!.t0 == 75)
        #expect(result.estimated)
    }

    @Test func disjointWindowsOwnSharedSpeechOnceAndKeepRepetition() async throws {
        let url = try captureFixtureAudio(seconds: 17)
        defer { try? FileManager.default.removeItem(at: url) }
        // Each sample identifies its absolute source position, independently of decode call order.
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        do {
            let writer = try AVAudioFile(forWriting: url, settings: format.settings)
            let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 272_000))
            pcm.frameLength = pcm.frameCapacity
            for index in 0..<272_000 { pcm.floatChannelData![0][index] = Float(index) / 1_000_000 }
            try writer.write(from: pcm)
        }
        let fixture = CaptureBoundaryFixture()
        let result = try await TranscriptionCoordinator().transcribeFeedbackCapture(at: url,
            preferred: nil, config: AppConfig(), installed: [.parakeetMultilingual]) { url, _, _ in
                try await fixture.decode(url)
            }
        #expect(!result.estimated)
        #expect(result.words.map(\.text) == ["go", "go", "menus", "now", "go", "go"])
        #expect(result.text == "go go menus now go go")
        #expect(result.words.map(\.t0) == [100, 500, 7500, 8200, 14800, 15500])
        #expect(result.segments.map(\.text).joined(separator: " ") == result.text)
        let coverage = await fixture.coverage
        #expect(coverage.count == 3)
        #expect(coverage.first?.lowerBound == 0 && coverage.last?.upperBound == 272_000)
        #expect(zip(coverage, coverage.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
        #expect(coverage.reduce(0) { $0 + $1.count } == 272_000)
        #expect(await fixture.menuCoverage == [120_000..<124_800])
        print("boundary source coverage: \(coverage); menu/menus source: \(await fixture.menuCoverage); output: \(result.text)")
    }

    @Test(arguments: CaptureBoundaryTiming.allCases, [false, true])
    fileprivate func incompleteOrJitteredTimingsStayInTheirDisjointChunk(reason: CaptureBoundaryTiming, laterIncomplete: Bool) async throws {
        let url = try captureFixtureAudio(seconds: 9)
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = CaptureIncompleteBoundaryFixture(reason: reason, laterIncomplete: laterIncomplete)
        let result = try await TranscriptionCoordinator().transcribeFeedbackCapture(at: url,
            preferred: .parakeetMultilingual, config: AppConfig(), installed: [.parakeetMultilingual]) { url, _, _ in
                try await fixture.decode(url)
            }
        let expected = reason == .ambiguousGo ? "go go" : "go go boundary now go go"
        #expect(result.text == expected)
        #expect(result.words.map(\.text).joined(separator: " ") == expected)
        #expect(result.segments.map(\.text) == (reason == .ambiguousGo ? ["go", "go"] : ["go go boundary", "now go go"]))
        #expect(result.estimated == (laterIncomplete || reason == .incompleteFirst || reason == .incompleteLater))
        #expect(result.words.first?.t0 == (reason == .incompleteFirst ? 0 : (reason == .ambiguousGo ? 6900 : 100)))
        #expect(result.words.last!.t1 <= 9000)
        #expect(await fixture.calls == 2)
        #expect(abs(await fixture.sourceSeconds - 9) < 0.0001)
        let cut: Int64 = 7025
        let split = reason == .ambiguousGo ? 1 : 3
        #expect(result.words.prefix(split).allSatisfy { $0.t0 >= 0 && $0.t1 <= cut })
        #expect(result.words.dropFirst(split).allSatisfy { $0.t0 >= cut && $0.t1 <= 9000 })
        if reason == .incompleteFirst { #expect(result.words[split - 1].t1 == cut) }
        else { #expect(result.words[split - 1].t1 == (reason == .ambiguousGo ? 7000 : 6800)) }
        if laterIncomplete || reason == .incompleteLater { #expect(result.words[split].t0 == cut && result.words.last?.t1 == 9000) }
        else { #expect(result.words[split].t0 == (reason == .exactJitter ? 7135 : 7125)) }
    }

    @Test func offlineWhisperWrapperUsesSelectedFolderAndLocalOnlyProducerLoad() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-whisper-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = ManagedASRModelPlans.whisperKit(modelName: "small", downloadRoot: root)
        for alternatives in plan.requiredArtifactAlternatives {
            let file = plan.cacheDirectory.appendingPathComponent(try #require(alternatives.first))
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([42]).write(to: file)
        }
        let calls = CaptureWhisperCalls()
        let transcriber = WhisperKitTranscriber(downloadRoot: root) { config in
            await calls.created()
            #expect(config.modelFolder == plan.cacheDirectory.path)
            #expect(config.load == false)
            #expect(config.download == false)
            // Keep deliberate wiring mutations from loading real weights or reaching the network.
            return try await CaptureWhisperKit(WhisperKitConfig(modelFolder: config.modelFolder,
                load: false, download: false), calls: calls)
        }
        await #expect(throws: CocoaError(.fileReadCorruptFile)) {
            try await ManagedASRModelDownloader.$localOnly.withValue(true) {
                try await transcriber.loadModel(modelName: "small")
            }
        }
        #expect(await calls.factoryCount == 1)
        #expect(await calls.localOnlyLoads == [true])
        #expect(await calls.defaultLoads == 0)
        #expect(plan.isAvailableLocally())
    }

    @Test func offlineVadRejectsAbsentAndCorruptAssetsWithoutRepair() async throws {
        guard #available(macOS 15, *) else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-vad-\(UUID()).mlmodelc")
        defer { try? FileManager.default.removeItem(at: directory) }
        for corrupt in [false, true] {
            if corrupt {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data([42]).write(to: directory.appendingPathComponent("model.mil"))
            }
            do {
                _ = try await ManagedASRModelDownloader.$localOnly.withValue(true) {
                    try await GemmaNativeAudioModels.loadVAD(modelURL: directory)
                }
                Issue.record("Missing/corrupt offline VAD must fail without downloading")
            } catch { #expect(error.localizedDescription.contains("Gemma VAD unavailable")) }
            #expect(FileManager.default.fileExists(atPath: directory.path) == corrupt)
        }
        #expect(try Data(contentsOf: directory.appendingPathComponent("model.mil")) == Data([42]))
    }

    @Test func cumulativeBudgetSurvivesPausesWithoutResetting() async throws {
        let result = await FeedbackCaptureTranscriptionJob().run(timeout: .milliseconds(70)) {
            await FeedbackCaptureTranscriptionJob.current?.setActive(false)
            try await FeedbackCaptureTranscriptionJob.withActiveWork { try await Task.sleep(for: .milliseconds(40)) }
            try await Task.sleep(for: .milliseconds(120))
            try await FeedbackCaptureTranscriptionJob.withActiveWork { try await Task.sleep(for: .milliseconds(50)) }
            return .init(source: "fixture", text: "budget incorrectly reset", words: [], segments: [], estimated: true)
        }
        #expect(result.missing?.reason == "transcription timed out after ten minutes")
    }

    @Test func permitWaitDoesNotConsumeActiveBudget() async throws {
        let coordinator = TranscriptionCoordinator()
        let gate = coordinator.inferenceGate
        try await gate.acquire()
        let url = try captureFixtureAudio(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task {
            await FeedbackCaptureTranscriptionJob().run(timeout: .milliseconds(500)) {
                try await coordinator.transcribeFeedbackCapture(at: url, preferred: nil,
                    config: AppConfig(), installed: [.parakeetUnified]) { _, _, _ in
                    SpeechTranscriptionResult(text: "queued", segments: [])
                }
            }
        }
        try await captureWaitUntil(timeout: .seconds(15)) { await gate.queuedWaiterCount() == 1 }
        try await Task.sleep(for: .milliseconds(1500))
        await gate.release()
        let result = await task.value
        #expect(result.missing == nil)
        #expect(result.text == "queued")
    }

    @Test @MainActor func recoveryUsesControllerFinalizerAndSkipsCheckpointedTranscript() async throws {
        try await withFeedbackStoreAsync { store, root in
            var refused: [(String, Data)] = []
            for futureVersion in [false, true] {
                let manifest = try store.begin(target: feedbackTarget())
                var body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
                body["version"] = 2
                let data = futureVersion ? try JSONSerialization.data(withJSONObject: body) : Data("corrupt".utf8)
                try data.write(to: store.mediaURL(id: manifest.id, path: "unfinished.json"))
                store.release(id: manifest.id)
                refused.append((manifest.id, data))
            }
            var savedIDs: [String] = []
            for checkpointed in [false, true] {
                var manifest = try store.begin(target: feedbackTarget())
                try WavWriter.writeWAV(samples: Array(repeating: Float(0), count: 1600),
                    to: store.mediaURL(id: manifest.id, path: "narration.wav"))
                if checkpointed {
                    manifest.transcript = .init(source: "fixture", text: "checkpointed",
                        words: [.init(t0: 0, t1: 100, text: "checkpointed")],
                        segments: [.init(t0: 0, t1: 100, text: "checkpointed")], estimated: true)
                }
                try store.checkpoint(manifest)
                store.release(id: manifest.id)
                savedIDs.append(manifest.id)
            }
            let calls = CaptureCallCounter()
            let controller = FeedbackCaptureController(databaseURL: root.appendingPathComponent("muesli.db"),
                supportDirectory: root, observeSystem: false)
            controller.finalizer.stages = [FeedbackCaptureFinalizer.transcriptionStage { _ in
                await calls.increment()
                return .init(source: "fixture", text: "resumed",
                    words: [.init(t0: 0, t1: 100, text: "resumed")],
                    segments: [.init(t0: 0, t1: 100, text: "resumed")], estimated: true)
            }]
            await controller.recover()
            #expect(await calls.count == 1)
            #expect(controller.records.filter { savedIDs.contains($0.id) }.allSatisfy { $0.state == .recovered })
            for (id, data) in refused {
                #expect(controller.errorMessage?.contains(id) == true)
                #expect(try Data(contentsOf: store.mediaURL(id: id, path: "unfinished.json")) == data)
                #expect(try store.list().first { $0.id == id }?.state == .recording)
            }
            #expect(try store.manifest(id: savedIDs[0]).transcript?.text == "resumed")
            #expect(try store.manifest(id: savedIDs[1]).transcript?.text == "checkpointed")
            await controller.recover()
            #expect(await calls.count == 1)
        }
    }

    @Test func installedSelectionNeverUsesHostedOrUnsupportedModels() {
        let installed: [BackendOption] = [.parakeetMultilingual, .parakeetUnified, .whisperSmall]
        #expect(BackendOption.feedbackCaptureBackend(preferred: .whisperSmall, installed: installed) == .whisperSmall)
        #expect(BackendOption.feedbackCaptureBackend(preferred: nil, installed: installed) == .parakeetMultilingual)
        #expect(BackendOption.feedbackCaptureBackend(preferred: .qwen3Asr, installed: []) == nil)
        #expect(BackendOption.feedbackCaptureBackend(preferred: .appleSpeechAnalyzer, installed: installed) == .parakeetMultilingual)
    }

    @Test(arguments: ["wrongType", "missingEstimated", "missingWords"])
    func malformedOptionalTranscriptKeepsCaptureOpenable(corruption: String) throws {
        try withFeedbackStore { store, _, _ in
            let manifest = try store.begin(target: feedbackTarget())
            var body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
            var transcript: [String: Any] = [
                "source": "fixture", "model": "fixture", "text": "open this",
                "words": [], "segments": [], "estimated": true,
            ]
            switch corruption {
            case "wrongType": transcript["words"] = "invalid"
            case "missingEstimated": transcript.removeValue(forKey: "estimated")
            case "missingWords": transcript.removeValue(forKey: "words")
            default: Issue.record("Unexpected transcript corruption case: \(corruption)")
            }
            body["transcript"] = transcript
            let data = try JSONSerialization.data(withJSONObject: body)
            try data.write(to: store.mediaURL(id: manifest.id, path: "unfinished.json"))
            store.release(id: manifest.id)

            let opened = try #require(try store.get(id: manifest.id))
            #expect(opened.id == manifest.id)
            #expect(opened.title == "Fixture Editor")
            #expect(try store.manifest(id: manifest.id).transcript == nil)
        }
    }

    @Test func measuredExtractionAndWhisperOptIn() {
        let tokens = [TokenTiming(token: "▁open", tokenId: 1, startTime: 0.1, endTime: 0.3, confidence: 1),
                      TokenTiming(token: "ing", tokenId: 2, startTime: 0.3, endTime: 0.5, confidence: 1),
                      TokenTiming(token: "▁this", tokenId: 3, startTime: 0.6, endTime: 0.8, confidence: 1)]
        #expect(FluidAudioTranscriber.captureWords(tokens).map(\.text) == ["opening", "this"])
        #expect(FluidAudioTranscriber.captureWords(tokens).first?.end == 0.5)
        #expect(SpeechTranscriptionResult(text: "dictation", segments: []).words == nil)
    }

    @Test func titleAndProjectionFollowStorePublication() throws {
        try withFeedbackStore { store, db, _ in
            var manifest = try store.begin(target: feedbackTarget())
            #expect(try store.get(id: manifest.id)?.title == "Fixture Editor")
            manifest.transcript = .init(source: "fixture", text: "Open the menu, then choose this.", words: [], segments: [], estimated: true)
            try store.publish(manifest)
            #expect(try store.get(id: manifest.id)?.title == "Open the menu")
            var statement: OpaquePointer?
            #expect(sqlite3_prepare_v2(db, "SELECT body FROM feedback_captures", -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            #expect(sqlite3_step(statement) == SQLITE_ROW)
            let body = String(cString: sqlite3_column_text(statement, 0))
            let json = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
            #expect(json["transcriptSource"] as? String == "fixture")
            store.release(id: manifest.id)
        }
    }

    @Test func foregroundWinsNextSlot() async throws {
        let gate = InferenceGate()
        try await gate.acquire()
        let background = Task { try await gate.acquire(background: true); return "background" }
        try await captureWaitUntil { await gate.queuedWaiterCount() >= 1 }
        let foreground = Task { try await gate.acquire(); return "foreground" }
        try await captureWaitUntil { await gate.queuedWaiterCount() >= 2 }
        await gate.release()
        #expect(try await foreground.value == "foreground")
        await gate.release()
        #expect(try await background.value == "background")
        await gate.release()
    }
    @Test func cancellationWhileWaitingDoesNotConsumePermit() async throws {
        let gate = InferenceGate()
        try await gate.acquire()
        let task = Task {
            await FeedbackCaptureTranscriptionJob().run {
                try await gate.acquire(background: true)
                await gate.release()
                return .init(source: "fixture", text: "unexpected", words: [], segments: [], estimated: true)
            }
        }
        try await captureWaitUntil { await gate.queuedWaiterCount() > 0 }
        task.cancel()
        #expect(await task.value.missing?.reason == "transcription cancelled")
        try await captureWaitUntil { await gate.queuedWaiterCount() == 0 }
        await gate.release()
        try await gate.acquire()
        await gate.release()
    }

    @Test @MainActor func failurePublishesReasonAndRetainsMedia() async throws {
        try await withFeedbackStoreAsync { store, _ in
            var manifest = try store.begin(target: feedbackTarget())
            manifest.audio = "narration.wav"; manifest.video = "recording.mp4"
            try Data([1, 2]).write(to: store.mediaURL(id: manifest.id, path: manifest.audio!))
            let stage = FeedbackCaptureFinalizer.transcriptionStage { _ in throw CocoaError(.fileReadCorruptFile) }
            let result = try await FeedbackCaptureFinalizer(stages: [stage]).finish(manifest,
                context: .init(store: store, finishPasteboardChangeCount: 0))
            #expect(result.state == .ready)
            #expect(result.transcript?.missing?.reason.isEmpty == false)
            #expect(result.failures.map(\.stage) == ["transcribe"])
            #expect(try Data(contentsOf: store.mediaURL(id: manifest.id, path: manifest.audio!)) == Data([1, 2]))
            #expect(try store.manifest(id: manifest.id) == result)
            store.release(id: manifest.id)
        }
    }

    @Test(arguments: [false, true])
    func windowOffsetsAndLanguageSnapshot(estimated: Bool) async throws {
        let url = try captureFixtureAudio(seconds: 17.001)
        defer { try? FileManager.default.removeItem(at: url) }
        var config = AppConfig()
        config.whisperLanguage = "uk"
        config.parakeetLanguage = "uk"
        let result = try await TranscriptionCoordinator().transcribeFeedbackCapture(at: url,
            preferred: estimated ? .parakeetUnified : .parakeetMultilingual, config: config,
            installed: [estimated ? .parakeetUnified : .parakeetMultilingual]) { url, backend, snapshot in
                #expect(backend == (estimated ? .parakeetUnified : .parakeetMultilingual))
                #expect(snapshot.resolvedWhisperLanguage == .ukrainian)
                #expect(snapshot.resolvedParakeetLanguage == .ukrainian)
                #expect(ManagedASRModelDownloader.localOnly)
                let file = try AVAudioFile(forReading: url)
                let duration = Double(file.length) / file.processingFormat.sampleRate
                return SpeechTranscriptionResult(text: "open this", segments: [.init(start: 0, end: duration, text: "open this")],
                    words: estimated ? nil : [.init(start: 0.1, end: 0.3, text: "open"), .init(start: 0.5, end: 0.8, text: "this")])
            }
        #expect(result.estimated == estimated)
        #expect(result.source == (estimated ? "parakeet-unified" : "fluidaudio"))
        #expect(result.words.map(\.text) == ["open", "this", "open", "this", "open", "this"])
        #expect(result.segments.count == 3)
        for index in result.segments.indices {
            let segment = result.segments[index]
            let words = Array(result.words[(index * 2)..<(index * 2 + 2)])
            #expect(words.allSatisfy { $0.t0 >= segment.t0 && $0.t1 <= segment.t1 })
        }
        #expect(result.words.last!.t1 <= 17001)
        #expect(result.words[2].t0 >= 7000)
        #expect(result.words[4].t0 >= 14000)
    }

    @Test func partialTimingsFallBackWithoutLosingWords() async throws {
        let url = try captureFixtureAudio(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await TranscriptionCoordinator().transcribeFeedbackCapture(at: url,
            preferred: .parakeetMultilingual, config: AppConfig(), installed: [.parakeetMultilingual]) { _, _, _ in
                SpeechTranscriptionResult(text: "open this", segments: [],
                    words: [.init(start: 0.1, end: 0.2, text: "open")])
            }
        #expect(result.estimated)
        #expect(result.words.map(\.text) == ["open", "this"])
    }

    @Test func expiredInferenceKeepsItsWindowUntilNativeCompletion() async throws {
        let url = try captureFixtureAudio(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let coordinator = TranscriptionCoordinator()
        let native = CaptureFileLatch()
        let result = await FeedbackCaptureTranscriptionJob().run(timeout: .milliseconds(50)) {
            try await coordinator.transcribeFeedbackCapture(at: url, preferred: nil,
                config: AppConfig(), installed: [.parakeetUnified]) { window, _, _ in
                    #expect(Task.currentPriority == .background)
                    await native.wait(window)
                    return SpeechTranscriptionResult(text: "late", segments: [])
                }
        }
        #expect(result.missing?.reason == "transcription timed out after ten minutes")
        let window = try #require(await native.url)
        #expect(FileManager.default.fileExists(atPath: window.path))
        let gate = coordinator.inferenceGate
        let foreground = Task { try await gate.acquire(); await gate.release() }
        try await captureWaitUntil { await gate.queuedWaiterCount() > 0 }
        await native.finish()
        try await foreground.value
        try await captureWaitUntil { !FileManager.default.fileExists(atPath: window.path) }
    }

    @Test("Model library file downloads do not hold the inference permit")
    func whisperModelLibraryDownloadDoesNotHoldInferencePermit() async throws {
        let download = CaptureModelLibraryDownloadGate()
        let permitProbe = CaptureInferencePermitProbe()
        let coordinator = TranscriptionCoordinator(modelLibraryFileDownload: { _, _, _, _ in
            await download.pause()
        })
        let preload = Task {
            try await ManagedASRModelDownloader.$localOnly.withValue(true) {
                try await coordinator.preloadRequired(
                    backend: .whisperSmall,
                    includeMeetingHelpers: false,
                    meetingHelperTrigger: .modelLibrary
                )
            }
        }
        try await captureWaitUntil { await download.started }
        let inference = Task {
            try await coordinator.inferenceGate.withPermit {
                await permitProbe.markEntered()
            }
        }
        defer {
            preload.cancel()
            inference.cancel()
            Task { await download.release() }
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await permitProbe.entered), ContinuousClock.now < deadline { await Task.yield() }
        #expect(await permitProbe.entered, "Model library file download held the inference permit")

        preload.cancel()
        await download.release()
        _ = await inference.result
        switch await preload.result {
        case .success:
            Issue.record("Cancelled model preparation unexpectedly succeeded")
        case .failure(let error):
            #expect(error is CancellationError)
        }
    }

    @Test("Network-enabled preloads download before acquiring the inference permit")
    func nonLibraryPreloadDownloadDoesNotHoldInferencePermit() async throws {
        let download = CaptureModelLibraryDownloadGate()
        let coordinator = TranscriptionCoordinator(modelLibraryFileDownload: { _, _, _, _ in
            await download.pause()
        })
        let gate = coordinator.inferenceGate
        try await gate.acquire()
        let preload = Task {
            try await ManagedASRModelDownloader.$localOnly.withValue(false) {
                try await coordinator.preloadRequired(backend: .whisperSmall, includeMeetingHelpers: false)
            }
        }

        do {
            try await captureWaitUntil { await download.started }
        } catch {
            preload.cancel()
            await download.release()
            await gate.release()
            _ = await preload.result
            throw error
        }
        #expect(await gate.queuedWaiterCount() == 0,
            "A network-enabled preload queued behind the inference permit before downloading")

        preload.cancel()
        await download.release()
        switch await preload.result {
        case .success:
            Issue.record("Cancelled model preparation unexpectedly succeeded")
        case .failure(let error):
            #expect(error is CancellationError)
        }
        await gate.release()
    }

    @Test func dictationRestoresItsModelAfterCapturePreparation() async throws {
        let log = CaptureModelLog()
        let fluid = FluidAudioTranscriber { model, _, _ in
            await log.record(model)
            return AsrManager(config: .default)
        }
        let unifiedLoads = CaptureCallCounter()
        let modelLibraryDownloads = CaptureCallCounter()
        let coordinator = TranscriptionCoordinator(fluidAudioTranscriberFactory: { fluid },
            parakeetUnifiedTranscriberFactory: {
                ParakeetUnifiedTranscriber { _, _, _, _ in
                    await unifiedLoads.increment()
                    return UnifiedAsrManager()
                }
            }, modelLibraryFileDownload: { _, _, _, _ in
                await modelLibraryDownloads.increment()
            })
        try await ManagedASRModelDownloader.$localOnly.withValue(true) {
            try await coordinator.preloadRequired(backend: .parakeetEnglish, includeMeetingHelpers: false)
        }
        let url = try captureFixtureAudio(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        // Exercise capture preparation itself. Empty managers reject decode without real weights.
        await #expect(throws: (any Error).self) {
            _ = try await coordinator.transcribeFeedbackCapture(at: url, preferred: .parakeetMultilingual,
                config: AppConfig(), installed: [.parakeetMultilingual])
        }
        #expect(await fluid.loadedModelID == BackendOption.parakeetMultilingual.model)
        // The injected manager is synthetic; never download real Unified weights in this fixture.
        try await ManagedASRModelDownloader.$localOnly.withValue(true) {
            try await coordinator.preloadRequired(backend: .parakeetUnified, includeMeetingHelpers: false)
        }
        #expect(await modelLibraryDownloads.count == 0)
        #expect(await unifiedLoads.count == 1)
        for _ in 0..<2 {
            await #expect(throws: (any Error).self) {
                _ = try await coordinator.transcribeDictation(at: url, backend: .parakeetEnglish)
            }
            #expect(await fluid.loadedModelID == BackendOption.parakeetEnglish.model)
        }
        #expect(await log.models == [BackendOption.parakeetEnglish.model,
            BackendOption.parakeetMultilingual.model, BackendOption.parakeetEnglish.model])
    }

    @Test func captureLanguageOverrideDoesNotChangeNemotronPreference() async {
        guard #available(macOS 15, *) else { return }
        let transcriber = Nemotron35StreamingTranscriber()
        await transcriber.setPromptId(6)
        #expect(await transcriber.configuration(promptId: 9).promptId == 9)
        #expect(await transcriber.configuration().promptId == 6)
    }

    @Test func noModelAndNoSpeechHaveNamedReasons() async throws {
        let coordinator = TranscriptionCoordinator()
        let url = try captureFixtureAudio(seconds: 0.25)
        defer { try? FileManager.default.removeItem(at: url) }
        let absent = try await coordinator.transcribeFeedbackCapture(at: url,
            preferred: nil, config: AppConfig(), installed: [])
        #expect(absent.missing?.reason == "no on-device speech model installed")
        let silent = try await coordinator.transcribeFeedbackCapture(at: url,
            preferred: nil, config: AppConfig(), installed: [.parakeetUnified]) { _, _, _ in
                SpeechTranscriptionResult(text: "  ", segments: [])
            }
        #expect(silent.missing?.reason == "no speech recognized")
    }

    @Test("Gemma capture preserves repeated words across a bounded narration window")
    func gemmaCapturePreservesRepeatedWordsAcrossBoundedWindow() async throws {
        let url = try captureFixtureAudio(seconds: 8)
        defer { try? FileManager.default.removeItem(at: url) }
        let calls = CaptureCallCounter()
        let result = try await TranscriptionCoordinator().transcribeFeedbackCapture(at: url,
            preferred: .gemma4E2BLiteRT, config: AppConfig(), installed: [.gemma4E2BLiteRT]) { candidate, backend, _ in
                #expect(backend.backend == "gemma4-litert")
                let wav = try WavReader.readFloatMonoWAV(from: candidate)
                #expect(wav.sampleRate == 16_000)
                #expect(wav.samples.count == 128_000)
                await calls.increment()
                let text: String
                if wav.samples.count >= 128_000 {
                    text = "we should go, go after"
                } else if wav.samples.count > 60_000 {
                    text = "we should go"
                } else {
                    text = "go after"
                }
                return SpeechTranscriptionResult(text: text, segments: [])
            }
        #expect(result.text == "we should go, go after")
        #expect(await calls.count == 1)
    }

    @Test("Cohere capture skips quiet windows before inference")
    func cohereCaptureSkipsQuietWindowsBeforeInference() async throws {
        let url = try captureFixtureAudio(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let calls = CaptureCallCounter()
        let coordinator = TranscriptionCoordinator(captureSpeechDetectorFactory: { { _ in false } })
        let result = try await coordinator.transcribeFeedbackCapture(at: url,
            preferred: .cohereTranscribe, config: AppConfig(), installed: [.cohereTranscribe]) { _, _, _ in
                await calls.increment()
                return SpeechTranscriptionResult(text: "hallucinated words", segments: [])
            }
        #expect(result.missing?.reason == "no speech recognized")
        #expect(await calls.count == 0)
    }

    @Test("Cohere capture loads one detector for all windows")
    func cohereCaptureLoadsDetectorOnceAcrossWindows() async throws {
        let url = try captureFixtureAudio(seconds: 17)
        defer { try? FileManager.default.removeItem(at: url) }
        let factoryCalls = CaptureCallCounter()
        let detectorCalls = CaptureCallCounter()
        let coordinator = TranscriptionCoordinator(
            captureSpeechDetectorFactory: {
                await factoryCalls.increment()
                return { _ in
                    await detectorCalls.increment()
                    return false
                }
            }
        )
        let result = try await coordinator.transcribeFeedbackCapture(at: url,
            preferred: .cohereTranscribe, config: AppConfig(), installed: [.cohereTranscribe])
        #expect(result.missing?.reason == "no speech recognized")
        #expect(await factoryCalls.count == 1)
        #expect(await detectorCalls.count == 3)
    }

    @Test("Cohere capture reports detector failure without decoding")
    func cohereCapturePropagatesSpeechDetectorFailure() async throws {
        let url = try captureFixtureAudio(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let calls = CaptureCallCounter()
        let coordinator = TranscriptionCoordinator(captureSpeechDetectorFactory: {
            { _ in throw CaptureSpeechDetectionError.unavailable }
        })
        do {
            _ = try await coordinator.transcribeFeedbackCapture(at: url,
                preferred: .cohereTranscribe, config: AppConfig(), installed: [.cohereTranscribe]) { _, _, _ in
                    await calls.increment()
                    return SpeechTranscriptionResult(text: "hallucinated words", segments: [])
                }
            Issue.record("Expected Cohere speech detector failure")
        } catch is CaptureSpeechDetectionError {
            #expect(await calls.count == 0)
        } catch {
            Issue.record("Unexpected detector error: \(error)")
        }
    }

    @Test func localOnlyLoadKeepsFailedArtifactsAndSkipsMissingModels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-local-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = ManagedASRModelPlan(modelID: "fixture", repository: "fixture/asr", cacheDirectory: root,
            selections: [HuggingFaceModelSelection(includedPaths: ["model.bin"])], requiredArtifactAlternatives: [["model.bin"]])
        await #expect(throws: CocoaError.self) {
            try await ManagedASRModelDownloader.$localOnly.withValue(true) {
                try await ManagedASRModelDownloader.downloadIfNeeded(plan)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("model.bin")
        try Data([42]).write(to: file)
        await #expect(throws: CocoaError.self) {
            try await ManagedASRModelDownloader.$localOnly.withValue(true) {
                try await ManagedASRModelDownloader.loadValidated(plan) { _ in throw CocoaError(.fileReadCorruptFile) }
            }
        }
        #expect(try Data(contentsOf: file) == Data([42]))
        #expect(plan.requiresRuntimeValidation())
    }

    @Test("transcription result logs include character counts, not transcript text")
    func transcriptionResultLogsDoNotIncludeText() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: packageRoot.appendingPathComponent(
            "Sources/MuesliNativeApp/TranscriptionRuntime.swift"), encoding: .utf8)
        let resultLogs = source.components(separatedBy: .newlines).filter {
            $0.contains("fputs(") && ($0.contains(" result:") || $0.contains(" result chars="))
        }
        #expect(resultLogs.count == 7)
        #expect(resultLogs.allSatisfy {
            $0.contains("result chars=") && $0.contains(".text.count") && !$0.contains(".text.prefix")
        })
    }

}


private func captureFixtureAudio(seconds: Double) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-fixture-\(UUID()).wav")
    let count = Int(seconds * 16_000) * 2
    var data = WavWriter.header(dataSize: UInt32(count))
    data.append(Data(repeating: 0, count: count))
    try data.write(to: url)
    return url
}

private enum CaptureSpeechDetectionError: Error {
    case unavailable
}

private func captureWaitUntil(timeout: Duration = .seconds(3), _ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(await predicate(), "Timed out waiting for capture fixture")
}

private actor CaptureModelLibraryDownloadGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor CaptureInferencePermitProbe {
    private(set) var entered = false

    func markEntered() {
        entered = true
    }
}

private actor CaptureFileLatch {
    private(set) var url: URL?
    private var continuation: CheckedContinuation<Void, Never>?
    func wait(_ url: URL) async {
        self.url = url
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(); continuation = nil }
}

private actor CaptureModelLog {
    private(set) var models: [String] = []
    func record(_ model: String) { models.append(model) }
}

@MainActor private final class CaptureForegroundActivity { var busy = true }

private actor CaptureBoundaryFixture {
    private(set) var coverage: [Range<Int>] = []
    private(set) var menuCoverage: [Range<Int>] = []
    func decode(_ url: URL) throws -> SpeechTranscriptionResult {
        let file = try AVAudioFile(forReading: url)
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        var samples: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: pcm)
            try #require(pcm.frameLength > 0)
            samples += UnsafeBufferPointer(start: try #require(pcm.floatChannelData?[0]), count: Int(pcm.frameLength))
        }
        let start = Int((samples[0] * 1_000_000).rounded())
        let end = start + samples.count
        #expect(end - start <= 128_000)
        #expect(samples.indices.allSatisfy { abs(samples[$0] - Float(start + $0) / 1_000_000) < 0.000001 })
        coverage.append(start..<end)
        let speech: [(Int, Int, String)] = [(1600, 4800, "go"), (8000, 11200, "go"),
            (120_000, 124_800, start == 0 ? "menu" : "menus"), (131_200, 136_000, "now"),
            (236_800, 240_000, "go"), (248_000, 252_800, "go")]
        let words = speech.filter { $0.0 >= start && $0.1 <= end }.map { first, last, text in
            if text == "menu" || text == "menus" { menuCoverage.append(first..<last) }
            return SpeechSegment(start: Double(first - start) / 16_000,
                end: Double(last - start) / 16_000, text: text)
        }
        return .init(text: words.map(\.text).joined(separator: " "), segments: words, words: words)
    }
}

private enum CaptureBoundaryTiming: CaseIterable, Sendable {
    case incompleteFirst, incompleteLater, exactJitter, ambiguousGo
}

private actor CaptureIncompleteBoundaryFixture {
    let reason: CaptureBoundaryTiming
    let laterIncomplete: Bool
    private(set) var calls = 0
    private(set) var sourceSeconds: Double = 0
    init(reason: CaptureBoundaryTiming, laterIncomplete: Bool) {
        self.reason = reason; self.laterIncomplete = laterIncomplete
    }
    func decode(_ url: URL) throws -> SpeechTranscriptionResult {
        let file = try AVAudioFile(forReading: url)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        #expect(seconds <= 8)
        let first = calls == 0
        calls += 1
        sourceSeconds += seconds
        let words: [SpeechSegment] = first
            ? [.init(start: 0.1, end: 0.3, text: "go"), .init(start: 0.5, end: 0.7, text: "go"),
               .init(start: 6.5, end: 6.8, text: "boundary")]
            : [.init(start: reason == .exactJitter ? 0.11 : 0.1, end: 0.3, text: "now"),
               .init(start: 0.5, end: 0.7, text: "go"), .init(start: 1, end: 1.2, text: "go")]
        let retained = reason == .ambiguousGo
            ? [SpeechSegment(start: first ? 6.9 : 0.1, end: first ? 7.0 : 0.3, text: "go")] : words
        let text = retained.map(\.text).joined(separator: " ")
        let incomplete = first ? reason == .incompleteFirst : (laterIncomplete || reason == .incompleteLater)
        return .init(text: text, segments: [.init(start: 0, end: seconds, text: text)],
            words: incomplete ? Array(retained.dropLast()) : retained)
    }
}

private actor CaptureCallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private actor CaptureWhisperCalls {
    private(set) var factoryCount = 0
    private(set) var localOnlyLoads: [Bool] = []
    private(set) var defaultLoads = 0
    func created() { factoryCount += 1 }
    func loaded(localFilesOnly: Bool) { localOnlyLoads.append(localFilesOnly) }
    func loadedDefault() { defaultLoads += 1 }
}

private final class CaptureWhisperKit: WhisperKit {
    private let calls: CaptureWhisperCalls

    init(_ config: WhisperKitConfig, calls: CaptureWhisperCalls) async throws {
        self.calls = calls
        try await super.init(config)
    }

    override func loadModels(prewarmMode: Bool = false, localFilesOnly: Bool) async throws {
        await calls.loaded(localFilesOnly: localFilesOnly)
        throw CocoaError(.fileReadCorruptFile)
    }

    override func loadModels(prewarmMode: Bool = false) async throws {
        await calls.loadedDefault()
        throw CocoaError(.fileReadCorruptFile)
    }
}
