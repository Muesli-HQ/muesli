@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os

final class MicrophoneRecorder: @unchecked Sendable {
    var preferredInputDeviceID: AudioObjectID?
    var keepsAudioGraphWarm = false
    var onFirstCapturedAudioBuffer: ((Date) -> Void)?

    private struct FileState {
        var fileHandle: FileHandle?
        var fileURL: URL?
        var bytesWritten: Int = 0
        var latestPowerDB: Float = -160
        var isPaused = false
        var isCapturing = false
        var hasReceivedFirstAudioBuffer = false
    }

    private static let sampleRate: Double = 16_000
    private static let bufferSize: AVAudioFrameCount = 1024

    private let engine = AVAudioEngine()
    private let lock = OSAllocatedUnfairLock(initialState: FileState())
    private let lifecycleLock = NSRecursiveLock()
    private let writerQueue = DispatchQueue(label: "com.muesli.microphone-recorder-writer")
    private var isPrepared = false
    private var isRunning = false
    private var isGraphPrepared = false
    private var tapInstalled = false
    private var preparedInputDeviceID: AudioObjectID?

    func prepare() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard !isPrepared else { return }
        try ensurePreparedGraphLocked(preferredInputDeviceID: preferredInputDeviceID)

        let fileState = try createNewFile()
        lock.withLock { $0 = fileState }
        isPrepared = true
    }

    func warmUp(preferredInputDeviceID: AudioObjectID?) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        self.preferredInputDeviceID = preferredInputDeviceID
        guard !isPrepared && !isRunning else {
            fputs("[mic-recorder] warmup deferred while capture is active\n", stderr)
            return
        }
        try ensurePreparedGraphLocked(preferredInputDeviceID: preferredInputDeviceID)
    }

    func activateWarmEngine(preferredInputDeviceID: AudioObjectID?) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        self.preferredInputDeviceID = preferredInputDeviceID
        guard !isPrepared && !isRunning else {
            fputs("[mic-recorder] activation deferred while capture is active\n", stderr)
            return
        }
        try ensurePreparedGraphLocked(preferredInputDeviceID: preferredInputDeviceID)
        guard !engine.isRunning else { return }
        lock.withLock { state in
            state.isCapturing = false
            state.isPaused = false
            state.latestPowerDB = -160
            state.hasReceivedFirstAudioBuffer = false
        }
        do {
            try engine.start()
        } catch {
            stopWarmGraphLocked()
            throw error
        }
        fputs(
            "[mic-recorder] warm engine activated preferredInput=\(preferredInputDeviceID.map(String.init) ?? "default")\n",
            stderr
        )
    }

    func coolDown() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard !isPrepared && !isRunning else { return }
        stopWarmGraphLocked()
    }

    private func ensurePreparedGraphLocked(preferredInputDeviceID: AudioObjectID?) throws {
        if isGraphPrepared, preparedInputDeviceID == preferredInputDeviceID {
            return
        }
        if isRunning {
            return
        }

        stopWarmGraphLocked()

        AudioInputDeviceSelection.applyPreferredInputDeviceID(
            preferredInputDeviceID,
            to: engine,
            logPrefix: "mic-recorder"
        )

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw NSError(domain: "MicrophoneRecorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No audio input available",
            ])
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "MicrophoneRecorder", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not create target audio format",
            ])
        }

        let needsConversion = hwFormat.sampleRate != Self.sampleRate || hwFormat.channelCount != 1
        let converter = needsConversion ? AVAudioConverter(from: hwFormat, to: targetFormat) : nil

        fputs(
            "[mic-recorder] preparing graph preferredInput=\(preferredInputDeviceID.map(String.init) ?? "default") hwRate=\(Int(hwFormat.sampleRate)) channels=\(hwFormat.channelCount)\n",
            stderr
        )
        inputNode.installTap(onBus: 0, bufferSize: Self.bufferSize, format: nil) { [weak self] buffer, _ in
            self?.handleAudioBuffer(buffer, converter: converter, targetFormat: targetFormat)
        }
        tapInstalled = true
        engine.prepare()
        isGraphPrepared = true
        preparedInputDeviceID = preferredInputDeviceID
    }

    func start() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard !isRunning else { return }
        try prepare()

        do {
            if !engine.isRunning {
                try ensurePreparedGraphLocked(preferredInputDeviceID: preferredInputDeviceID)
                lock.withLock { state in
                    state.isCapturing = true
                    state.isPaused = false
                    state.latestPowerDB = -160
                    state.hasReceivedFirstAudioBuffer = false
                }
                try engine.start()
            } else {
                lock.withLock { state in
                    state.isCapturing = true
                    state.isPaused = false
                    state.latestPowerDB = -160
                    state.hasReceivedFirstAudioBuffer = false
                }
            }
            isRunning = true
        } catch {
            isRunning = false
            lock.withLock { state in
                state.isCapturing = false
                state.latestPowerDB = -160
            }
            stopWarmGraphLocked()
            throw error
        }
    }

    func stop() -> URL? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard isPrepared else { return nil }
        isRunning = false

        let finalState = lock.withLock { state -> FileState in
            let old = state
            state = FileState()
            return old
        }
        isPrepared = false
        engine.stop()
        waitForPendingWrites()
        if keepsAudioGraphWarm {
            lock.withLock { $0.latestPowerDB = -160 }
        } else {
            stopWarmGraphLocked()
        }

        return finalizeFile(finalState)
    }

    func pause() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard isPrepared else { return }
        lock.withLock { state in
            state.isPaused = true
            state.latestPowerDB = -160
        }
    }

    func resume() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard isPrepared else { return }
        lock.withLock { state in
            state.isPaused = false
        }
    }

    func currentPower() -> Float {
        lock.withLock { $0.latestPowerDB }
    }

    func cancel() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        isRunning = false
        isPrepared = false

        let state = lock.withLock { state -> FileState in
            let old = state
            state = FileState()
            return old
        }
        engine.stop()
        waitForPendingWrites()
        state.fileHandle?.closeFile()
        if let url = state.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        if keepsAudioGraphWarm {
            lock.withLock { $0.latestPowerDB = -160 }
        } else {
            stopWarmGraphLocked()
        }
    }

    private func handleAudioBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter?,
        targetFormat: AVAudioFormat
    ) {
        let capturedAt = Date()
        let shouldCapture = lock.withLock { state -> Bool in
            guard state.isCapturing, !state.isPaused else {
                state.latestPowerDB = -160
                return false
            }
            return true
        }
        guard shouldCapture else { return }

        let monoBuffer: AVAudioPCMBuffer
        if let converter {
            let frameCapacity = max(
                1,
                AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / buffer.format.sampleRate)
            )
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
                return
            }
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            converter.convert(to: converted, error: &error, withInputFrom: inputBlock)
            guard error == nil else { return }
            monoBuffer = converted
        } else {
            monoBuffer = buffer
        }

        guard let floatData = monoBuffer.floatChannelData?[0] else { return }
        let frameCount = Int(monoBuffer.frameLength)
        guard frameCount > 0 else { return }

        var sumSquares: Float = 0
        var pcmData = Data(count: frameCount * MemoryLayout<Int16>.size)
        pcmData.withUnsafeMutableBytes { rawBuffer in
            guard let output = rawBuffer.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<frameCount {
                let sample = floatData[i]
                let clamped = max(-1.0, min(1.0, sample))
                output[i] = Int16(clamped * 32767)
                sumSquares += sample * sample
            }
        }

        let rms = sqrt(sumSquares / Float(frameCount))
        let rawDB = rms > 0.000_001 ? 20 * log10(rms) : -160
        let powerDB = max(-160, min(0, rawDB))
        let pcmByteCount = pcmData.count
        let dataToWrite = pcmData

        let writeTarget = lock.withLock { state -> (FileHandle?, Bool) in
            guard state.isCapturing, !state.isPaused else {
                state.latestPowerDB = -160
                return (nil, false)
            }
            let shouldNotifyFirstBuffer = !state.hasReceivedFirstAudioBuffer
            if !state.hasReceivedFirstAudioBuffer {
                state.hasReceivedFirstAudioBuffer = true
            }
            state.bytesWritten += pcmByteCount
            state.latestPowerDB = powerDB
            return (state.fileHandle, shouldNotifyFirstBuffer)
        }
        if let handle = writeTarget.0 {
            writerQueue.async { [dataToWrite] in
                handle.write(dataToWrite)
            }
        }
        if writeTarget.1 {
            onFirstCapturedAudioBuffer?(capturedAt)
        }
    }

    private func createNewFile() throws -> FileState {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-native", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw NSError(domain: "MicrophoneRecorder", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Could not open file for writing",
            ])
        }
        handle.write(WavWriter.header(dataSize: 0))
        return FileState(fileHandle: handle, fileURL: url)
    }

    private func finalizeFile(_ state: FileState) -> URL? {
        guard let handle = state.fileHandle, let url = state.fileURL else { return nil }
        handle.seek(toFileOffset: 0)
        handle.write(WavWriter.header(dataSize: UInt32(state.bytesWritten)))
        handle.closeFile()

        if state.bytesWritten == 0 {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    private func waitForPendingWrites() {
        writerQueue.sync {}
    }

    private func removeTapIfNeeded() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    private func stopWarmGraphLocked() {
        removeTapIfNeeded()
        engine.stop()
        isGraphPrepared = false
        preparedInputDeviceID = nil
    }
}
