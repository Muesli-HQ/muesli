import AVFoundation
import AudioGraphExceptionBridge
import CoreAudio
import Foundation
import os

/// Mic recorder using AVAudioEngine for real-time buffer access.
/// Used by MeetingSession for VAD-driven chunk rotation (zero-gap file switching).
protocol StreamingDictationRecording: AnyObject {
    var onAudioBuffer: (([Float]) -> Void)? { get set }
    var onRecordingFailed: ((Error) -> Void)? { get set }
    var preferredInputDeviceID: AudioObjectID? { get set }

    func prepare() throws
    func start() throws
    func stop() -> URL?
    func cancel()
    func currentPower() -> Float

    /// Permanently disqualify this recorder instance from ever starting
    /// capture again. Unlike cancel() (which disposes but allows re-prepare),
    /// this is terminal and synchronous, so a stale handoff worker that calls
    /// start() after meeting teardown loses the race no matter the
    /// interleaving. Default no-op for recorders that don't need it.
    func invalidateForTeardown()
}

extension StreamingDictationRecording {
    func invalidateForTeardown() {}
}

protocol StreamingDictationLatencyReporting: AnyObject {
    var onLatencyEvent: ((String, Date) -> Void)? { get set }
}

protocol PausableStreamingDictationRecording: AnyObject {
    func pause()
    func resume()
}

/// Configure before starting capture. The producer checks this before accepting
/// a buffer; delayed delivery retains that decision across pause and stop.
protocol BufferedMicrophoneAdmissionControlling: AnyObject {
    var shouldAdmitSamples: (() -> Bool)? { get set }
    var hasBufferedSampleAdmission: Bool { get }
}

extension BufferedMicrophoneAdmissionControlling {
    var hasBufferedSampleAdmission: Bool { true }
}

struct StreamingMicRecorderRunState: Equatable {
    private(set) var isRunning = false

    mutating func markStarted() {
        isRunning = true
    }

    mutating func markStopped() {
        isRunning = false
    }

    mutating func markConfigurationChangeRestartFailed() {
        isRunning = false
    }
}

final class StreamingMicRecorder: StreamingDictationRecording, StreamingDictationLatencyReporting, PausableStreamingDictationRecording, BufferedMicrophoneAdmissionControlling {
    var shouldAdmitSamples: (() -> Bool)?
    /// Called with 4096-sample Float chunks (256ms at 16kHz) for VAD processing.
    var onAudioBuffer: (([Float]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var onLatencyEvent: ((String, Date) -> Void)?
    /// Called with 16-bit PCM mono samples for retained meeting recording.
    var onPCMSamples: (([Int16]) -> Void)?
    var preferredInputDeviceID: AudioObjectID?

    // Construct native graphs only on the driver path, never while a route
    // decision creates a recorder. graphLock owns this storage.
    private var engineStorage: AVAudioEngine?
    private var engine: AVAudioEngine {
        if let engineStorage { return engineStorage }
        let created = AVAudioEngine()
        engineStorage = created
        return created
    }
    private let directoryName: String
    private let recoversFromInputConfigurationChanges: Bool
    private let observesInputConfigurationChanges: Bool
    private let graphLock = NSRecursiveLock()
    /// Published independently of graphLock: invalidateForTeardown() must land
    /// even while a worker is blocked in engine startup holding graphLock, so
    /// the post-start self-check observes it before start() returns.
    private let teardownInvalidation = OSAllocatedUnfairLock(initialState: false)
    private let lock = OSAllocatedUnfairLock(initialState: FileState())
    private let failureLock = OSAllocatedUnfairLock(initialState: FailureState())
    private let failureCallbackQueue = DispatchQueue(label: "com.muesli.streaming-mic-recorder-failures")
    private var runState = StreamingMicRecorderRunState()
    private var tapInstalled = false
    private var graphPreparedInputDeviceID: AudioObjectID?
    private var isGraphPrepared = false
    private var configurationChangeObserver: (any NSObjectProtocol)?
    private let configurationChangeQueue = DispatchQueue(label: "com.muesli.streaming-mic-recorder-config-change")
    private let processingQueue = DispatchQueue(label: "com.muesli.streaming-mic-recorder-processing", qos: .userInitiated)
    private let captureLock = OSAllocatedUnfairLock<BufferedMicrophoneCapture?>(initialState: nil)
    private var bufferedCapture: BufferedMicrophoneCapture? {
        get { captureLock.withLock { $0 } }
        set { captureLock.withLock { $0 = newValue } }
    }

    private struct FailureState {
        var activeRecordingID: UUID?
        var hasReportedFailure = false
    }

    private struct FileState {
        var fileHandle: FileHandle?
        var fileURL: URL?
        var bytesWritten: Int = 0
        var latestPowerDB: Float = -160
        var isPaused = false
    }

    private static let sampleRate: Double = 16_000
    private static let bufferSize: AVAudioFrameCount = 4096 // 256ms at 16kHz

    init(
        directoryName: String = "muesli-meeting-mic",
        recoversFromInputConfigurationChanges: Bool = false,
        observesInputConfigurationChanges: Bool? = nil
    ) {
        self.directoryName = directoryName
        self.recoversFromInputConfigurationChanges = recoversFromInputConfigurationChanges
        self.observesInputConfigurationChanges = observesInputConfigurationChanges
            ?? recoversFromInputConfigurationChanges
    }

    deinit {
        // Safety net for callers that drop the recorder without stop()/cancel().
        if let observer = configurationChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func prepare() throws {
        graphLock.lock()
        defer { graphLock.unlock() }
        guard !isPermanentlyInvalidated else {
            throw NSError(domain: "StreamingMicRecorder", code: 9, userInfo: [
                NSLocalizedDescriptionKey: "Recorder was invalidated by teardown",
            ])
        }

        try prepareLocked()
    }

    private func prepareLocked() throws {
        if isGraphPrepared,
           graphPreparedInputDeviceID == preferredInputDeviceID {
            emitLatency("app_scoped_prepare_reused")
            return
        }

        emitLatency("app_scoped_prepare_begin")
        if recoversFromInputConfigurationChanges {
            if let preferredInputDeviceID,
               let error = MuesliAudioGraphSetInputDevice(engine, preferredInputDeviceID) {
                throw error
            }
        } else {
            AudioInputDeviceSelection.applyPreferredInputDeviceID(
                preferredInputDeviceID,
                to: engine,
                logPrefix: "streaming-mic"
            )
        }
        emitLatency("app_scoped_preferred_input_applied")

        let hwFormat = try inputFormatLocked()
        guard hwFormat.sampleRate > 0 else {
            isGraphPrepared = false
            graphPreparedInputDeviceID = nil
            throw NSError(domain: "StreamingMicRecorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No audio input available",
            ])
        }
        if recoversFromInputConfigurationChanges {
            if let error = MuesliAudioGraphPrepareEngine(engine) { throw error }
        } else {
            engine.prepare()
        }
        isGraphPrepared = true
        graphPreparedInputDeviceID = preferredInputDeviceID
        emitLatency("app_scoped_prepare_end")
    }

    func start() throws {
        graphLock.lock()
        defer { graphLock.unlock() }

        guard !isPermanentlyInvalidated else {
            throw NSError(domain: "StreamingMicRecorder", code: 9, userInfo: [
                NSLocalizedDescriptionKey: "Recorder was invalidated by teardown",
            ])
        }
        guard !runState.isRunning else { return }
        try prepareLocked()
        let recordingID = try beginRecordingFile()

        installConfigurationChangeObserverIfNeeded(recordingID: recordingID)
        do {
            try startEngineWithTapLocked(recordingID: recordingID)
            // Engine start can block while the daemon negotiates the route;
            // teardown may have landed during that window. Synchronously stop
            // what just started rather than letting capture outlive teardown.
            if isPermanentlyInvalidated {
                bufferedCapture?.close()
                stopEngineSafely()
                removeTapIfNeeded()
                processingQueue.sync {}
                removeConfigurationChangeObserverIfNeeded()
                clearFailureState()
                let state = lock.withLock { state -> FileState in
                    let old = state
                    state = FileState()
                    return old
                }
                state.fileHandle?.closeFile()
                if let url = state.fileURL {
                    try? FileManager.default.removeItem(at: url)
                }
                throw NSError(domain: "StreamingMicRecorder", code: 9, userInfo: [
                    NSLocalizedDescriptionKey: "Recorder was invalidated by teardown",
                ])
            }
            runState.markStarted()
        } catch {
            bufferedCapture?.close()
            stopEngineSafely()
            removeTapIfNeeded()
            processingQueue.sync {}
            bufferedCapture = nil
            removeConfigurationChangeObserverIfNeeded()
            clearFailureState()
            let state = lock.withLock { state -> FileState in
                let old = state
                state = FileState()
                return old
            }
            state.fileHandle?.closeFile()
            if let url = state.fileURL {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    /// Installs the input tap (with conversion to 16kHz mono) and starts the engine.
    /// Callers hold `graphLock`. Shared by `start()` and the configuration-change
    /// restart path, so the tap keeps appending to the current file.
    private func startEngineWithTapLocked(recordingID: UUID) throws {
        let hwFormat = try inputFormatLocked()
        let tapBlock = try makeBufferedTap(format: hwFormat, recordingID: recordingID)

        emitLatency("app_scoped_tap_install_begin")
        if recoversFromInputConfigurationChanges {
            if let tapError = MuesliAudioGraphInstallInputTap(engine, 0, Self.bufferSize, nil, tapBlock) {
                throw tapError
            }
        } else {
            engine.inputNode.installTap(onBus: 0, bufferSize: Self.bufferSize, format: nil, block: tapBlock)
        }
        tapInstalled = true
        emitLatency("app_scoped_tap_install_end")

        emitLatency("app_scoped_engine_start_begin")
        if recoversFromInputConfigurationChanges {
            if let error = MuesliAudioGraphStartEngine(engine) { throw error }
        } else {
            try engine.start()
        }
        emitLatency("app_scoped_engine_start_end")
    }

    private func makeBufferedTap(format hwFormat: AVAudioFormat, recordingID: UUID) throws -> AVAudioNodeTapBlock {

        // Target format: 16kHz mono Float32
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "StreamingMicRecorder", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not create target audio format",
            ])
        }

        // Install converter if sample rates differ
        let needsConversion = hwFormat.sampleRate != Self.sampleRate || hwFormat.channelCount != 1
            || hwFormat.commonFormat != .pcmFormatFloat32
        let converter: AVAudioConverter? = needsConversion
            ? AVAudioConverter(from: hwFormat, to: targetFormat)
            : nil
        guard !needsConversion || converter != nil else {
            throw Self.runtimeError(code: 4, message: "Could not create microphone sample-rate converter")
        }

        // AVAudioEngine's requested tap size is a hint. Leave room for normal
        // hardware-sized batches, including high-rate USB interfaces.
        guard hwFormat.sampleRate.isFinite, hwFormat.sampleRate > 0,
              hwFormat.sampleRate <= Double(UInt32.max) else {
            throw Self.runtimeError(code: 11, message: "Invalid microphone sample rate")
        }
        let maximumFrames = AVAudioFrameCount(max(16_384, ceil(hwFormat.sampleRate / 4)))
        let capture = try BufferedMicrophoneCapture(
            format: hwFormat, queue: processingQueue, maximumFrames: maximumFrames,
            shouldAdmitSamples: shouldAdmitSamples ?? { true }
        ) { [weak self] buffer in
            guard let self else { return }
            guard self.isCurrentRecording(recordingID) else { return }

            let monoBuffer: AVAudioPCMBuffer
            if let converter {
                let frameCapacity = AVAudioFrameCount(
                    max(1, Double(buffer.frameLength) * Self.sampleRate / buffer.format.sampleRate)
                )
                guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
                    self.reportRecordingFailure(
                        Self.runtimeError(code: 4, message: "Could not allocate converted microphone buffer"),
                        recordingID: recordingID
                    )
                    return
                }
                var error: NSError?
                var didProvideInput = false
                let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                    guard !didProvideInput else {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    didProvideInput = true
                    outStatus.pointee = .haveData
                    return buffer
                }
                converter.convert(to: converted, error: &error, withInputFrom: inputBlock)
                if let error {
                    self.reportRecordingFailure(error, recordingID: recordingID)
                    return
                }
                monoBuffer = converted
            } else {
                monoBuffer = buffer
            }

            guard let floatData = monoBuffer.floatChannelData?[0] else {
                self.reportRecordingFailure(
                    Self.runtimeError(code: 5, message: "Microphone buffer did not contain float channel data"),
                    recordingID: recordingID
                )
                return
            }
            let frameCount = Int(monoBuffer.frameLength)

            // Write Int16 PCM to file
            var int16Samples = [Int16](repeating: 0, count: frameCount)
            for i in 0..<frameCount {
                let clamped = max(-1.0, min(1.0, floatData[i]))
                int16Samples[i] = Int16(clamped * 32767)
            }
            let pcmData = int16Samples.withUnsafeBufferPointer { Data(buffer: $0) }
            let powerDB: Float = {
                guard frameCount > 0 else { return -160 }
                var sumSquares: Float = 0
                for i in 0..<frameCount {
                    let sample = floatData[i]
                    sumSquares += sample * sample
                }
                let rms = sqrt(sumSquares / Float(frameCount))
                let rawDB = rms > 0.000_001 ? 20 * log10(rms) : -160
                return max(-160, min(0, rawDB))
            }()

            // File lifecycle is serialized on processingQueue. Snapshot the
            // handle so currentPower()/pause() never wait behind disk I/O.
            guard let handle = self.lock.withLock({ $0.fileHandle }) else { return }
            do {
                try handle.write(contentsOf: pcmData)
            } catch {
                self.bufferedCapture?.close()
                self.reportRecordingFailure(error, recordingID: recordingID)
                return
            }
            self.lock.withLock { state in
                state.bytesWritten += pcmData.count
                state.latestPowerDB = state.isPaused ? -160 : powerDB
            }

            self.onPCMSamples?(int16Samples)

            // Forward Float samples for VAD (in 4096-sample chunks)
            let floats = Array(UnsafeBufferPointer(start: floatData, count: frameCount))
            self.onAudioBuffer?(floats)
        }
        capture.setPaused(lock.withLock { $0.isPaused })
        bufferedCapture = capture
        return { [weak self, capture] buffer, _ in
            switch capture.offer(buffer) {
            case .accepted, .ignored: break
            case .overflow:
                self?.reportRecordingFailure(
                    Self.runtimeError(code: 10, message: "Microphone processing could not keep up with capture"),
                    recordingID: recordingID
                )
            case .invalidBuffer:
                self?.reportRecordingFailure(
                    Self.runtimeError(code: 11, message: "Microphone callback format or size changed unexpectedly"),
                    recordingID: recordingID
                )
            }
        }
    }

    private func beginRecordingFile() throws -> UUID {
        let fileState = try createNewFile()
        lock.withLock { $0 = fileState }
        let recordingID = UUID()
        failureLock.withLock {
            $0.activeRecordingID = recordingID
            $0.hasReportedFailure = false
        }
        return recordingID
    }

    /// Exercises the real tap, conversion, writing and teardown without opening
    /// hardware. Native engine installation/start are the only omitted boundary.
    func testing_startWithTap(format: AVAudioFormat) throws -> AVAudioNodeTapBlock {
        let id = try beginRecordingFile()
        let tap = try makeBufferedTap(format: format, recordingID: id)
        runState.markStarted()
        return tap
    }

    private func inputFormatLocked() throws -> AVAudioFormat {
        if recoversFromInputConfigurationChanges {
            let state = MuesliAudioGraphReadInputState(engine)
            if let error = state.error { throw error }
            guard let format = state.outputFormat else {
                throw Self.runtimeError(code: 6, message: "Microphone input format is unavailable")
            }
            return format
        }
        return engine.inputNode.outputFormat(forBus: 0)
    }

    private var configChangeRestartItem: DispatchWorkItem?
    /// Settle debounce for engine config-change restarts. A route transition
    /// fires a burst of notifications while the daemon negotiates, and
    /// restarting mid-churn reliably fails tap installation (measured live on
    /// macOS 26.5.2, aged daemon). The current engine keeps its state during
    /// the window; we restart once after the notifications stop.
    /// (var so tests can inject a fast settle)
    var configChangeSettleDelay: TimeInterval = 1.5

    // MARK: - Input Configuration Changes

    /// AVAudioEngine stops delivering input buffers when its I/O configuration
    /// changes mid-recording (e.g. AirPods connect and become the default input).
    /// Without handling this, the microphone side of a meeting recording dies
    /// silently while system audio keeps flowing. Rebuild the tap and restart
    /// the engine so capture continues into the same file.
    private func installConfigurationChangeObserverIfNeeded(recordingID: UUID) {
        guard observesInputConfigurationChanges else { return }
        guard configurationChangeObserver == nil else { return }
        let callbackQueue = configurationChangeQueue
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            callbackQueue.async { [weak self] in
                self?.scheduleConfigurationChangeRestart(recordingID: recordingID)
            }
        }
    }

    private func scheduleConfigurationChangeRestart(recordingID: UUID) {
        // On configurationChangeQueue. Each notification resets the settle
        // timer; the restart fires once after the burst quiets.
        configChangeRestartItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.handleEngineConfigurationChange(recordingID: recordingID)
        }
        configChangeRestartItem = item
        configurationChangeQueue.asyncAfter(deadline: .now() + configChangeSettleDelay, execute: item)
    }

    private func removeConfigurationChangeObserverIfNeeded() {
        configChangeRestartItem?.cancel()
        configChangeRestartItem = nil
        guard let observer = configurationChangeObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        configurationChangeObserver = nil
    }

    private func handleEngineConfigurationChange(recordingID: UUID) {
        graphLock.lock()
        defer { graphLock.unlock() }

        guard runState.isRunning else { return }
        let mayRestart = failureLock.withLock {
            $0.activeRecordingID == recordingID && !$0.hasReportedFailure
        }
        guard mayRestart else { return }

        fputs("[streaming-mic] engine configuration changed; restarting input capture\n", stderr)
        emitLatency("engine_config_change_restart_begin")
        bufferedCapture?.close()
        stopEngineSafely()
        removeTapIfNeeded()
        processingQueue.sync {}
        bufferedCapture = nil
        isGraphPrepared = false
        graphPreparedInputDeviceID = nil

        do {
            try prepareLocked()
            try startEngineWithTapLocked(recordingID: recordingID)
            emitLatency("engine_config_change_restart_end")
            fputs("[streaming-mic] microphone capture restarted after configuration change\n", stderr)
        } catch {
            fputs("[streaming-mic] failed to restart microphone capture after configuration change: \(error)\n", stderr)
            // startEngineWithTapLocked() can fail after installing the tap; drop it so
            // tapInstalled stays consistent with the stopped engine. Remove the observer
            // too: once the failure is reported this recording must not silently resume
            // on a later configuration change.
            bufferedCapture?.close()
            stopEngineSafely()
            removeTapIfNeeded()
            processingQueue.sync {}
            bufferedCapture = nil
            removeConfigurationChangeObserverIfNeeded()
            runState.markConfigurationChangeRestartFailed()
            reportRecordingFailure(error, recordingID: recordingID)
        }
    }

    /// Rotate to a new file. Returns the completed WAV URL. No audio gap.
    func rotateFile() -> URL? {
        // Serialize with graph replacement/teardown before entering the worker.
        // This can wait for an in-flight native restart; call off MainActor and
        // never from a recorder delivery callback (which runs on processingQueue).
        graphLock.lock()
        defer { graphLock.unlock() }
        guard runState.isRunning else { return nil }

        return processingQueue.sync { rotateFileOnProcessingQueue() }
    }

    private func rotateFileOnProcessingQueue() -> URL? {

        let newState: FileState
        do {
            newState = try createNewFile()
        } catch {
            fputs("[streaming-mic] failed to create new file during rotation: \(error)\n", stderr)
            return nil
        }

        let completed = lock.withLock { state -> FileState in
            let old = state
            state = newState
            state.isPaused = old.isPaused
            return old
        }

        return finalizeFile(completed)
    }

    /// Stop recording. Returns the final WAV URL.
    func stop() -> URL? {
        graphLock.lock()
        defer { graphLock.unlock() }

        guard runState.isRunning || lock.withLock({ $0.fileHandle != nil }) else { return nil }
        runState.markStopped()
        removeConfigurationChangeObserverIfNeeded()

        bufferedCapture?.close()
        stopEngineSafely()
        removeTapIfNeeded()
        // Flush every buffer accepted before Stop, including callback delivery,
        // before invalidating the generation or finalizing the WAV header.
        processingQueue.sync {}
        bufferedCapture = nil
        clearFailureState()

        let finalState = lock.withLock { state -> FileState in
            let old = state
            state = FileState()
            return old
        }

        return finalizeFile(finalState)
    }

    func pause() {
        guard runState.isRunning else { return }
        bufferedCapture?.setPaused(true)
        lock.withLock { state in
            state.isPaused = true
            state.latestPowerDB = -160
        }
    }

    func resume() {
        guard runState.isRunning else { return }
        lock.withLock { state in
            state.isPaused = false
        }
        bufferedCapture?.setPaused(false)
    }

    /// Terminal and synchronous: this instance must never start capture again
    /// after meeting teardown. Distinct from cancel(), which permits reuse.
    func invalidateForTeardown() {
        teardownInvalidation.withLock { $0 = true }
        bufferedCapture?.close()
    }

    private var isPermanentlyInvalidated: Bool {
        teardownInvalidation.withLock { $0 }
    }

    func cancel() {
        graphLock.lock()
        defer { graphLock.unlock() }

        runState.markStopped()
        clearFailureState()
        removeConfigurationChangeObserverIfNeeded()
        bufferedCapture?.close()
        stopEngineSafely()
        removeTapIfNeeded()
        processingQueue.sync {}
        bufferedCapture = nil
        isGraphPrepared = false
        graphPreparedInputDeviceID = nil
        engineStorage = nil
        onAudioBuffer = nil
        onPCMSamples = nil
        onRecordingFailed = nil

        let state = lock.withLock { state -> FileState in
            let old = state
            state = FileState()
            return old
        }
        state.fileHandle?.closeFile()
        if let url = state.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Approximate current power level (dB) from recent samples.
    func currentPower() -> Float {
        lock.withLock { $0.latestPowerDB }
    }

    // Call only after stopping the engine: removing a tap from a running
    // engine reinitializes its input chain and can deadlock behind a route
    // rebind (captured during the AirPods Stop Transcribing failure).
    private func removeTapIfNeeded() {
        guard tapInstalled else { return }
        if recoversFromInputConfigurationChanges {
            _ = MuesliAudioGraphRemoveInputTap(engine, 0)
        } else {
            engine.inputNode.removeTap(onBus: 0)
        }
        tapInstalled = false
    }

    private func stopEngineSafely() {
        guard let engine = engineStorage else { return }
        if recoversFromInputConfigurationChanges {
            _ = MuesliAudioGraphStopEngine(engine)
        } else {
            engine.stop()
        }
    }

    private func isCurrentRecording(_ recordingID: UUID) -> Bool {
        failureLock.withLock { $0.activeRecordingID == recordingID }
    }

    private func clearFailureState() {
        failureLock.withLock {
            $0.activeRecordingID = nil
            $0.hasReportedFailure = true
        }
    }

    private func emitLatency(_ event: String, at date: Date = Date()) {
        onLatencyEvent?(event, date)
    }

    private func reportRecordingFailure(_ error: Error, recordingID: UUID) {
        let callback = failureLock.withLock { state -> ((Error) -> Void)? in
            guard state.activeRecordingID == recordingID,
                  !state.hasReportedFailure else { return nil }
            state.hasReportedFailure = true
            return onRecordingFailed
        }
        guard let callback else { return }
        failureCallbackQueue.async {
            callback(error)
        }
    }

    private static func runtimeError(code: Int, message: String) -> NSError {
        NSError(domain: "StreamingMicRecorder", code: code, userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }

    // MARK: - File Management

    private func createNewFile() throws -> FileState {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw NSError(domain: "StreamingMicRecorder", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Could not open file for writing",
            ])
        }
        // Write placeholder WAV header (will be finalized on close)
        handle.write(WavWriter.header(dataSize: 0))
        return FileState(fileHandle: handle, fileURL: url, bytesWritten: 0)
    }

    private func finalizeFile(_ state: FileState) -> URL? {
        guard let handle = state.fileHandle, let url = state.fileURL else { return nil }

        // Rewrite WAV header with correct data size
        handle.seek(toFileOffset: 0)
        handle.write(WavWriter.header(dataSize: UInt32(state.bytesWritten)))
        handle.closeFile()

        if state.bytesWritten == 0 {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

}
