import FluidAudio
import Foundation
import os

/// Bridges real-time meeting audio to VadManager's streaming API.
///
/// The key requirement here is single-flight state ownership: exactly one chunk
/// may be processed against the mutable stream state at a time. Chunks can
/// arrive faster than VAD inference finishes, so we queue them and drain
/// serially rather than spawning overlapping Tasks that race the same state.
final class StreamingVadController: @unchecked Sendable {
    /// Called when VAD detects a natural chunk boundary.
    /// Delivery is not main-thread guaranteed; handlers must dispatch before
    /// touching queue- or actor-isolated state.
    var onChunkBoundary: (() -> Void)?

    private struct State {
        var generation = 0
        var drainerEpoch = 0
        var isActive = false
        var isDraining = false
        var pendingChunks: [[Float]] = []
        var streamState: VadStreamState?
        var lastRotationTime: Date?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let makeInitialState: @Sendable () async -> VadStreamState
    private let processStreamChunk: @Sendable ([Float], VadStreamState) async throws -> VadStreamResult
    private let logger = Logger(subsystem: "com.muesli.native", category: "StreamingVadController")

    /// Minimum chunk duration before allowing rotation (prevents rapid flipping).
    private let minChunkDuration: TimeInterval
    /// Maximum chunk duration before forcing rotation (safety cap).
    private let maxChunkDuration: TimeInterval
    private var maxDurationTimer: Timer?

    convenience init(vadManager: VadManager) {
        self.init(
            minChunkDuration: 3.0,
            maxChunkDuration: 60.0,
            makeInitialState: { await vadManager.makeStreamState() },
            processStreamChunk: { samples, state in
                try await vadManager.processStreamingChunk(samples, state: state)
            }
        )
    }

    internal init(
        minChunkDuration: TimeInterval,
        maxChunkDuration: TimeInterval,
        makeInitialState: @escaping @Sendable () async -> VadStreamState,
        processStreamChunk: @escaping @Sendable ([Float], VadStreamState) async throws -> VadStreamResult
    ) {
        self.minChunkDuration = minChunkDuration
        self.maxChunkDuration = maxChunkDuration
        self.makeInitialState = makeInitialState
        self.processStreamChunk = processStreamChunk
    }

    func start() {
        let startGeneration = lock.withLock { state -> Int? in
            guard !state.isActive else { return nil }
            state.generation += 1
            state.isActive = true
            state.isDraining = false
            state.pendingChunks.removeAll(keepingCapacity: true)
            state.streamState = nil
            state.lastRotationTime = Date()
            return state.generation
        }
        guard let startGeneration else { return }

        Task { [weak self] in
            guard let self else { return }
            let initialState = await self.makeInitialState()
            let shouldKickDrain = self.lock.withLock { state in
                guard state.isActive, state.generation == startGeneration else { return false }
                state.streamState = initialState
                return !state.pendingChunks.isEmpty
            }
            if shouldKickDrain {
                self.startDrainIfNeeded()
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.maxDurationTimer?.invalidate()
            guard self.lock.withLock({ $0.isActive && $0.generation == startGeneration }) else { return }
            self.maxDurationTimer = Timer.scheduledTimer(withTimeInterval: self.maxChunkDuration, repeats: true) { [weak self] _ in
                self?.handleMaxDurationTimer()
            }
        }
    }

    func stop() {
        let stopGeneration = lock.withLock { state in
            state.isActive = false
            state.pendingChunks.removeAll(keepingCapacity: false)
            state.streamState = nil
            return state.generation
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.lock.withLock({ !$0.isActive && $0.generation == stopGeneration }) else { return }
            self.maxDurationTimer?.invalidate()
            self.maxDurationTimer = nil
        }
    }

    /// Feed a chunk of Float audio samples (typically 4096 samples = 256ms at 16kHz).
    func processAudio(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        let shouldStart = lock.withLock { state in
            guard state.isActive else { return false }
            state.pendingChunks.append(samples)
            return state.streamState != nil && !state.isDraining
        }

        if shouldStart {
            startDrainIfNeeded()
        }
    }

    /// Notify that an external rotation just happened.
    func notifyRotation() {
        lock.withLock { state in
            state.lastRotationTime = Date()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.maxDurationTimer?.fireDate = Date().addingTimeInterval(self.maxChunkDuration)
        }
    }

    private func handleMaxDurationTimer() {
        let shouldRotate = lock.withLock { state in
            guard state.isActive else { return false }
            let now = Date()
            let elapsed = now.timeIntervalSince(state.lastRotationTime ?? now)
            guard elapsed >= self.minChunkDuration else { return false }
            state.lastRotationTime = now
            return true
        }
        guard shouldRotate else { return }
        fputs("[vad] max chunk duration reached, forcing rotation\n", stderr)
        DispatchQueue.main.async { [weak self] in
            self?.onChunkBoundary?()
        }
    }

    private func startDrainIfNeeded() {
        let drainerEpoch = lock.withLock { state -> Int? in
            guard state.isActive, state.streamState != nil, !state.isDraining else { return nil }
            guard !state.pendingChunks.isEmpty else { return nil }
            state.drainerEpoch += 1
            state.isDraining = true
            return state.drainerEpoch
        }
        guard let drainerEpoch else { return }

        Task { [weak self] in
            await self?.drainQueue(drainerEpoch: drainerEpoch)
        }
    }

    private func drainQueue(drainerEpoch: Int) async {
        while true {
            let next: (generation: Int, chunk: [Float], streamState: VadStreamState)? = lock.withLock { state in
                guard state.isActive, state.isDraining, state.drainerEpoch == drainerEpoch else {
                    if !state.isActive {
                        state.isDraining = false
                        state.pendingChunks.removeAll(keepingCapacity: false)
                    }
                    return nil
                }
                guard let streamState = state.streamState else {
                    state.isDraining = false
                    return nil
                }
                guard !state.pendingChunks.isEmpty else {
                    state.isDraining = false
                    return nil
                }
                return (state.generation, state.pendingChunks.removeFirst(), streamState)
            }

            guard let next else { return }

            do {
                let result = try await processStreamChunk(next.chunk, next.streamState)

                let shouldRotate = lock.withLock { state in
                    guard state.isActive, state.generation == next.generation else { return false }
                    state.streamState = result.state

                    guard let event = result.event, event.kind == .speechEnd else {
                        return false
                    }

                    let now = Date()
                    let elapsed = now.timeIntervalSince(state.lastRotationTime ?? now)
                    guard elapsed >= self.minChunkDuration else { return false }
                    state.lastRotationTime = now
                    return true
                }

                if shouldRotate {
                    fputs("[vad] speech end detected, rotating chunk\n", stderr)
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.onChunkBoundary?()
                        self.maxDurationTimer?.fireDate = Date().addingTimeInterval(self.maxChunkDuration)
                    }
                }
            } catch {
                logger.error("streaming VAD chunk failed: \(String(describing: error), privacy: .public)")
                fputs("[vad] streaming chunk failed: \(error)\n", stderr)
            }
        }
    }
}
