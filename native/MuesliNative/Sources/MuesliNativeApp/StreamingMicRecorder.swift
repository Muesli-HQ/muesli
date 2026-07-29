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
}

protocol StreamingDictationLatencyReporting: AnyObject {
    var onLatencyEvent: ((String, Date) -> Void)? { get set }
}

protocol PausableStreamingDictationRecording: AnyObject {
    func pause()
    func resume()
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

final class StreamingMicRecorder: StreamingDictationRecording, StreamingDictationLatencyReporting, PausableStreamingDictationRecording {
    /// Called with 4096-sample Float chunks (256ms at 16kHz) for VAD processing.
    var onAudioBuffer: (([Float]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var onLatencyEvent: ((String, Date) -> Void)?
    /// Called with 16-bit PCM mono samples for retained meeting recording.
    var onPCMSamples: (([Int16]) -> Void)?
    var preferredInputDeviceID: AudioObjectID?

    private let engine = AVAudioEngine()
    private let directoryName: String
    private let recoversFromInputConfigurationChanges: Bool
    private let graphLock = NSRecursiveLock()
    private let lock = OSAllocatedUnfairLock(initialState: FileState())
    private let failureLock = OSAllocatedUnfairLock(initialState: FailureState())
    private let failureCallbackQueue = DispatchQueue(label: "com.muesli.streaming-mic-recorder-failures")
    private var runState = StreamingMicRecorderRunState()
    private var tapInstalled = false
    private var graphPreparedInputDeviceID: AudioObjectID?
    private var isGraphPrepared = false
    private var configurationChangeObserver: (any NSObjectProtocol)?
    private let configurationChangeQueue = DispatchQueue(label: "com.muesli.streaming-mic-recorder-config-change")

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
        recoversFromInputConfigurationChanges: Bool = false
    ) {
        self.directoryName = directoryName
        self.recoversFromInputConfigurationChanges = recoversFromInputConfigurationChanges
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

        guard !runState.isRunning else { return }
        try prepareLocked()
        let recordingID = UUID()
        failureLock.withLock {
            $0.activeRecordingID = recordingID
            $0.hasReportedFailure = false
        }

        let fileState = try createNewFile()
        lock.withLock { $0 = fileState }

        installConfigurationChangeObserverIfNeeded(recordingID: recordingID)
        do {
            try startEngineWithTapLocked(recordingID: recordingID)
            runState.markStarted()
        } catch {
            removeTapIfNeeded()
            stopEngineSafely()
            removeConfigurationChangeObserverIfNeeded()
            clearFailureState()
            let state = lock.withLock { state -> FileState in
                let old = state
                state = FileState()
                return old
            }
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
        let converter: AVAudioConverter? = needsConversion
            ? AVAudioConverter(from: hwFormat, to: targetFormat)
            : nil

        emitLatency("app_scoped_tap_install_begin")
        let tapBlock: AVAudioNodeTapBlock = { [weak self] buffer, _ in
            guard let self else { return }
            guard self.isCurrentRecording(recordingID) else { return }

            let monoBuffer: AVAudioPCMBuffer
            if let converter {
                let frameCapacity = AVAudioFrameCount(
                    Double(buffer.frameLength) * Self.sampleRate / buffer.format.sampleRate
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

            let shouldEmit = self.lock.withLock { state -> Bool in
                guard !state.isPaused else {
                    state.latestPowerDB = -160
                    return false
                }
                state.fileHandle?.write(pcmData)
                state.bytesWritten += pcmData.count
                state.latestPowerDB = powerDB
                return true
            }
            guard shouldEmit else { return }

            self.onPCMSamples?(int16Samples)

            // Forward Float samples for VAD (in 4096-sample chunks)
            let floats = Array(UnsafeBufferPointer(start: floatData, count: frameCount))
            self.onAudioBuffer?(floats)
        }
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

    // MARK: - Input Configuration Changes

    /// AVAudioEngine stops delivering input buffers when its I/O configuration
    /// changes mid-recording (e.g. AirPods connect and become the default input).
    /// Without handling this, the microphone side of a meeting recording dies
    /// silently while system audio keeps flowing. Rebuild the tap and restart
    /// the engine so capture continues into the same file.
    private func installConfigurationChangeObserverIfNeeded(recordingID: UUID) {
        guard recoversFromInputConfigurationChanges else { return }
        guard configurationChangeObserver == nil else { return }
        let callbackQueue = configurationChangeQueue
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            callbackQueue.async { [weak self] in
                self?.handleEngineConfigurationChange(recordingID: recordingID)
            }
        }
    }

    private func removeConfigurationChangeObserverIfNeeded() {
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
        removeTapIfNeeded()
        stopEngineSafely()
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
            removeTapIfNeeded()
            stopEngineSafely()
            removeConfigurationChangeObserverIfNeeded()
            runState.markConfigurationChangeRestartFailed()
            reportRecordingFailure(error, recordingID: recordingID)
        }
    }

    /// Rotate to a new file. Returns the completed WAV URL. No audio gap.
    func rotateFile() -> URL? {
        guard runState.isRunning else { return nil }

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
            return old
        }

        return finalizeFile(completed)
    }

    /// Stop recording. Returns the final WAV URL.
    func stop() -> URL? {
        graphLock.lock()
        defer { graphLock.unlock() }

        guard runState.isRunning else { return nil }
        runState.markStopped()
        clearFailureState()
        removeConfigurationChangeObserverIfNeeded()

        removeTapIfNeeded()
        stopEngineSafely()

        let finalState = lock.withLock { state -> FileState in
            let old = state
            state = FileState()
            return old
        }

        return finalizeFile(finalState)
    }

    func pause() {
        guard runState.isRunning else { return }
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
    }

    func cancel() {
        graphLock.lock()
        defer { graphLock.unlock() }

        runState.markStopped()
        clearFailureState()
        removeConfigurationChangeObserverIfNeeded()
        removeTapIfNeeded()
        stopEngineSafely()
        isGraphPrepared = false
        graphPreparedInputDeviceID = nil
        onAudioBuffer = nil
        onPCMSamples = nil
        onRecordingFailed = nil

        let state = lock.withLock { state -> FileState in
            let old = state
            state = FileState()
            return old
        }
        if let url = state.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Approximate current power level (dB) from recent samples.
    func currentPower() -> Float {
        lock.withLock { $0.latestPowerDB }
    }

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
