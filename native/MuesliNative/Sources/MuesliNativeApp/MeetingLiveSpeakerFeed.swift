import Foundation
import MuesliCore
import os

/// Serial registry mutations plus revisions protect against reordered UI deliveries in one capture.
private actor MeetingLiveSpeakerPresentation {
    private var registry: MeetingLiveSpeakerRegistry
    private var sampleUnavailableAfter: [MeetingSpeakerKey.Channel: Double] = [:]
    private let publish: @Sendable (MeetingLiveSpeakerPresentationUpdate) -> Void
    init(epoch: UUID, publish: @escaping @Sendable (MeetingLiveSpeakerPresentationUpdate) -> Void) { registry = .init(epoch: epoch); self.publish = publish }
    func append(_ turns: [MeetingSpeakerTurn], channel: MeetingSpeakerKey.Channel) {
        for original in turns {
            var turn = original
            if let boundary = sampleUnavailableAfter[channel], turn.end > boundary { turn.sampleEligible = false }
            registry.append(turn, channel: channel)
        }
        emit()
    }
    func complete(_ window: MeetingSpeakerAudioWindow, segments: [MeetingLiveSpeakerSegment], failed: Bool) {
        registry.complete(channel: window.channel, start: window.start, end: window.end, segments: segments, failed: failed); emit()
    }
    func gaps(_ gaps: [MeetingSpeakerCoverageGap]) {
        for gap in gaps { registry.complete(channel: gap.channel, start: gap.start, end: gap.end, segments: [], failed: true) }; emit()
    }
    func pause(_ gaps: [MeetingSpeakerCoverageGap], samplesUnalignedAfter boundaries: [MeetingSpeakerKey.Channel: Double]) {
        for gap in gaps { registry.complete(channel: gap.channel, start: gap.start, end: gap.end, segments: [], failed: true) }
        for (channel, boundary) in boundaries where boundary.isFinite && boundary >= 0 {
            let cutoff = min(sampleUnavailableAfter[channel] ?? boundary, boundary)
            sampleUnavailableAfter[channel] = cutoff
            registry.withholdSamples(channel: channel, after: cutoff)
        }
        emit()
    }
    func advance(_ clocks: [MeetingSpeakerKey.Channel: Double]) {
        for (channel, time) in clocks { registry.advanceCaptured(channel: channel, to: time) }; emit()
    }
    func finish() { registry.finish(); emit() }
    func snapshot() -> MeetingSpeakerState { registry.state }
    private func emit() {
        guard let update = registry.takePresentationUpdate() else { return }
        publish(update)
    }
}

/// Audio callbacks append bounded PCM only. Model work and the capture-clock ticker are independent.
final class MeetingLiveSpeakerFeed: @unchecked Sendable {
    typealias Inference = @Sendable (MeetingSpeakerAudioWindow) async throws -> [MeetingLiveSpeakerSegment]
    private struct State {
        var active = true
        var draining = false
        var queue = MeetingSpeakerPCMQueue()
        var clocks: [MeetingSpeakerKey.Channel: Double] = [:]
        var worker: Task<Void, Never>?
    }
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let presentation: MeetingLiveSpeakerPresentation
    private let infer: Inference
    private var ticker: Task<Void, Never>?
    let epoch: UUID
    init(epoch: UUID, infer: @escaping Inference, publish: @escaping @Sendable (MeetingLiveSpeakerPresentationUpdate) -> Void) {
        self.epoch = epoch; self.infer = infer; presentation = .init(epoch: epoch, publish: publish)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                let clocks = self.lock.withLock { $0.active ? $0.clocks : nil }
                guard let clocks else { return }
                await self.presentation.advance(clocks)
            }
        }
    }
    deinit { ticker?.cancel(); lock.withLock { $0.worker?.cancel() } }
    func appendPCM(_ samples: [Float], channel: MeetingSpeakerKey.Channel, startSample: Int64) {
        let start = lock.withLock { state -> Bool in
            guard state.active else { return false }
            state.clocks[channel] = Double(startSample + Int64(samples.count)) / 16_000
            state.queue.append(samples, channel: channel, startSample: startSample)
            guard !state.draining, state.queue.pendingCount > 0 else { return false }
            state.draining = true; return true
        }
        if start {
            let worker = Task<Void, Never> { [weak self] in guard let self else { return }; await self.drain() }
            lock.withLock { state in if state.active { state.worker = worker } else { worker.cancel() } }
        }
    }
    func appendTurns(_ turns: [MeetingSpeakerTurn], channel: MeetingSpeakerKey.Channel) async {
        await presentation.append(turns, channel: channel)
    }
    func pause(samplesUnalignedAfter boundaries: [MeetingSpeakerKey.Channel: Double] = [:]) async {
        let gaps = lock.withLock { $0.queue.resetPartial() }
        await presentation.pause(gaps, samplesUnalignedAfter: boundaries)
    }
    func finish() async {
        ticker?.cancel()
        let gaps = lock.withLock { state in
            state.active = false; state.worker?.cancel()
            return state.queue.resetPartial()
        }
        await presentation.gaps(gaps); await presentation.finish()
    }
    func testingWaitForDrain() async { await lock.withLock { $0.worker }?.value }
    func testingState() async -> MeetingSpeakerState { await presentation.snapshot() }
    private func drain() async {
        while !Task.isCancelled {
            let next = lock.withLock { state -> (MeetingSpeakerAudioWindow?, [MeetingSpeakerCoverageGap])? in
                guard state.active else { state.draining = false; return nil }
                let gaps = state.queue.takeGaps(), window = state.queue.pop()
                if window == nil { state.draining = false }
                return (window, gaps)
            }
            guard let next else { return }
            await presentation.gaps(next.1)
            guard let window = next.0 else { return }
            let result: [MeetingLiveSpeakerSegment]
            let failed: Bool
            do { result = try await infer(window); failed = false }
            catch { result = []; failed = true }
            guard lock.withLock({ $0.active }), !Task.isCancelled else { return }
            await presentation.complete(window, segments: result, failed: failed)
        }
    }
}
