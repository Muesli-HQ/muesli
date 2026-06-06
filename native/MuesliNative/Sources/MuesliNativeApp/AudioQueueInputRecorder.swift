import AudioToolbox
import CoreAudio
import Foundation
import os

final class AudioQueueInputRecorder: StreamingDictationRecording, StreamingDictationLatencyReporting {
    var onAudioBuffer: (([Float]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var onLatencyEvent: ((String, Date) -> Void)?
    var preferredInputDeviceID: AudioObjectID?

    private static let sampleRate: Double = 16_000
    private static let framesPerBuffer: UInt32 = 4096
    private static let bufferCount = 3

    private let directoryName: String
    private let queueLock = NSRecursiveLock()
    private let stateLock = OSAllocatedUnfairLock(initialState: FileState())
    private let processingQueue = DispatchQueue(label: "com.muesli.audio-queue-input-recorder-processing")
    private let failureCallbackQueue = DispatchQueue(label: "com.muesli.audio-queue-input-recorder-failures")

    private var audioQueue: AudioQueueRef?
    private var queueCallbackUserData: UnsafeMutableRawPointer?
    private var buffers: [AudioQueueBufferRef] = []
    private var preparedInputDeviceID: AudioObjectID?
    private var isPrepared = false
    private var isRunning = false
    private var captureGeneration: UInt64 = 0

    private struct FileState {
        var fileHandle: FileHandle?
        var fileURL: URL?
        var bytesWritten = 0
        var latestPowerDB: Float = -160
    }

    init(directoryName: String = "muesli-native-dictation") {
        self.directoryName = directoryName
    }

    deinit {
        cancel()
    }

    func prepare() throws {
        queueLock.lock()
        defer { queueLock.unlock() }

        try prepareLocked()
    }

    func start() throws {
        queueLock.lock()
        defer { queueLock.unlock() }

        guard !isRunning else { return }
        try prepareLocked()

        guard let audioQueue else {
            throw Self.runtimeError(code: 1, message: "Audio queue was not initialized")
        }

        stateLock.withLock { $0 = FileState() }
        let fileState = try createNewFile()
        stateLock.withLock { $0 = fileState }

        for buffer in buffers {
            let status = AudioQueueEnqueueBuffer(audioQueue, buffer, 0, nil)
            guard status == noErr else {
                cleanupAfterStartFailure()
                throw Self.runtimeError(code: 2, message: "AudioQueueEnqueueBuffer failed: \(status)")
            }
        }

        captureGeneration &+= 1
        isRunning = true
        emitLatency("audio_queue_start_begin")
        let status = AudioQueueStart(audioQueue, nil)
        emitLatency("audio_queue_start_end")
        guard status == noErr else {
            isRunning = false
            captureGeneration &+= 1
            cleanupAfterStartFailure()
            throw Self.runtimeError(code: 3, message: "AudioQueueStart failed: \(status)")
        }
    }

    func stop() -> URL? {
        queueLock.lock()
        guard isRunning else {
            queueLock.unlock()
            return nil
        }
        isRunning = false
        let generationToFinish = captureGeneration
        let queueToStop = audioQueue
        queueLock.unlock()

        if let queueToStop {
            emitLatency("audio_queue_stop_begin")
            AudioQueueStop(queueToStop, true)
            emitLatency("audio_queue_stop_end")
        }

        emitLatency("audio_queue_processing_drain_begin")
        processingQueue.sync {}
        emitLatency("audio_queue_processing_drain_end")

        queueLock.lock()
        if captureGeneration == generationToFinish {
            captureGeneration &+= 1
        }
        queueLock.unlock()

        emitLatency("audio_queue_finalize_begin")
        let finalState = stateLock.withLock { state -> FileState in
            let old = state
            state = FileState()
            return old
        }
        let url = finalizeFile(finalState)
        emitLatency("audio_queue_finalize_end")
        return url
    }

    func cancel() {
        queueLock.lock()
        isRunning = false
        captureGeneration &+= 1
        let queueToDispose = audioQueue
        let callbackUserDataToRelease = queueCallbackUserData
        audioQueue = nil
        queueCallbackUserData = nil
        buffers.removeAll()
        preparedInputDeviceID = nil
        isPrepared = false
        queueLock.unlock()

        if let queueToDispose {
            emitLatency("audio_queue_cancel_stop_begin")
            AudioQueueStop(queueToDispose, true)
            emitLatency("audio_queue_cancel_stop_end")
            AudioQueueDispose(queueToDispose, true)
        }
        Self.releaseCallbackUserData(callbackUserDataToRelease)

        processingQueue.sync {}

        let state = stateLock.withLock { state -> FileState in
            let old = state
            state = FileState()
            return old
        }
        if let url = state.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func currentPower() -> Float {
        stateLock.withLock { $0.latestPowerDB }
    }

    private func prepareLocked() throws {
        if isPrepared, preparedInputDeviceID == preferredInputDeviceID {
            emitLatency("audio_queue_prepare_reused")
            return
        }

        disposeQueueLocked()
        emitLatency("audio_queue_prepare_begin")

        var format = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var queue: AudioQueueRef?
        let callbackUserData = Unmanaged.passRetained(self).toOpaque()
        emitLatency("audio_queue_new_input_begin")
        let newInputStatus = AudioQueueNewInput(
            &format,
            Self.inputCallback,
            callbackUserData,
            nil,
            nil,
            0,
            &queue
        )
        emitLatency("audio_queue_new_input_end")
        guard newInputStatus == noErr, let queue else {
            Self.releaseCallbackUserData(callbackUserData)
            throw Self.runtimeError(code: 4, message: "AudioQueueNewInput failed: \(newInputStatus)")
        }
        audioQueue = queue
        queueCallbackUserData = callbackUserData

        do {
            if let preferredInputDeviceID {
                try applyPreferredInputDeviceID(preferredInputDeviceID, to: queue)
            } else {
                emitLatency("audio_queue_preferred_input_default_route")
            }

            let bytesPerBuffer = Self.framesPerBuffer * format.mBytesPerFrame
            emitLatency("audio_queue_allocate_buffers_begin")
            for _ in 0..<Self.bufferCount {
                var buffer: AudioQueueBufferRef?
                let status = AudioQueueAllocateBuffer(queue, bytesPerBuffer, &buffer)
                guard status == noErr, let buffer else {
                    throw Self.runtimeError(code: 5, message: "AudioQueueAllocateBuffer failed: \(status)")
                }
                buffers.append(buffer)
            }
            emitLatency("audio_queue_allocate_buffers_end")
        } catch {
            disposeQueueLocked()
            throw error
        }

        preparedInputDeviceID = preferredInputDeviceID
        isPrepared = true
        emitLatency("audio_queue_prepare_end")
    }

    private func applyPreferredInputDeviceID(_ deviceID: AudioObjectID, to queue: AudioQueueRef) throws {
        emitLatency("audio_queue_device_uid_lookup_begin")
        guard var deviceUID = Self.deviceUID(for: deviceID) as CFString? else {
            throw Self.runtimeError(code: 6, message: "Could not resolve device UID for \(deviceID)")
        }
        emitLatency("audio_queue_device_uid_lookup_end")

        emitLatency("audio_queue_set_current_device_begin")
        let status = withUnsafePointer(to: &deviceUID) { pointer in
            AudioQueueSetProperty(
                queue,
                kAudioQueueProperty_CurrentDevice,
                pointer,
                UInt32(MemoryLayout<CFString>.size)
            )
        }
        emitLatency("audio_queue_set_current_device_end")
        guard status == noErr else {
            throw Self.runtimeError(code: 7, message: "AudioQueueSetProperty current device failed: \(status)")
        }
    }

    private static let inputCallback: AudioQueueInputCallback = { userData, queue, buffer, _, _, _ in
        guard let userData else { return }
        let recorder = Unmanaged<AudioQueueInputRecorder>.fromOpaque(userData).takeUnretainedValue()
        recorder.handleInputBuffer(queue: queue, buffer: buffer)
    }

    private func handleInputBuffer(queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        queueLock.lock()
        let shouldProcess = isRunning
        let generation = captureGeneration
        queueLock.unlock()
        guard shouldProcess else { return }

        let byteCount = Int(buffer.pointee.mAudioDataByteSize)
        guard byteCount > 0 else {
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
            return
        }

        let audioData = Data(bytes: buffer.pointee.mAudioData, count: byteCount)
        let enqueueStatus = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        if enqueueStatus != noErr {
            reportFailure(Self.runtimeError(code: 8, message: "AudioQueueEnqueueBuffer failed: \(enqueueStatus)"))
            return
        }

        processingQueue.async { [weak self] in
            self?.processAudioData(audioData, generation: generation)
        }
    }

    private func processAudioData(_ data: Data, generation: UInt64) {
        queueLock.lock()
        let shouldProcess = captureGeneration == generation
        queueLock.unlock()
        guard shouldProcess else { return }

        let sampleCount = data.count / MemoryLayout<Float>.size
        guard sampleCount > 0 else { return }

        let samples = data.withUnsafeBytes { rawBuffer -> [Float] in
            var decoded = [Float]()
            decoded.reserveCapacity(sampleCount)
            for offset in stride(from: 0, to: sampleCount * MemoryLayout<Float>.size, by: MemoryLayout<Float>.size) {
                decoded.append(rawBuffer.loadUnaligned(fromByteOffset: offset, as: Float.self))
            }
            return decoded
        }
        guard !samples.isEmpty else { return }

        var int16Samples = [Int16](repeating: 0, count: sampleCount)
        var sumSquares: Float = 0
        for index in samples.indices {
            let sample = samples[index]
            let clamped = max(-1.0, min(1.0, sample))
            int16Samples[index] = Int16(clamped * 32767)
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(sampleCount))
        let rawDB = rms > 0.000_001 ? 20 * log10(rms) : -160
        let powerDB = max(-160, min(0, rawDB))
        let pcmData = int16Samples.withUnsafeBufferPointer { Data(buffer: $0) }

        stateLock.withLock { state in
            state.fileHandle?.write(pcmData)
            state.bytesWritten += pcmData.count
            state.latestPowerDB = powerDB
        }
        onAudioBuffer?(samples)
    }

    private func cleanupAfterStartFailure() {
        disposeQueueLocked()
        let state = stateLock.withLock { state -> FileState in
            let old = state
            state = FileState()
            return old
        }
        if let url = state.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func disposeQueueLocked() {
        let callbackUserDataToRelease = queueCallbackUserData
        if let audioQueue {
            captureGeneration &+= 1
            AudioQueueStop(audioQueue, true)
            AudioQueueDispose(audioQueue, true)
        }
        audioQueue = nil
        queueCallbackUserData = nil
        buffers.removeAll()
        preparedInputDeviceID = nil
        isPrepared = false
        Self.releaseCallbackUserData(callbackUserDataToRelease)
    }

    private func reportFailure(_ error: Error) {
        failureCallbackQueue.async { [onRecordingFailed] in
            onRecordingFailed?(error)
        }
    }

    private func emitLatency(_ event: String, at date: Date = Date()) {
        onLatencyEvent?(event, date)
    }

    private static func runtimeError(code: Int, message: String) -> NSError {
        NSError(domain: "AudioQueueInputRecorder", code: code, userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }

    private static func releaseCallbackUserData(_ userData: UnsafeMutableRawPointer?) {
        guard let userData else { return }
        Unmanaged<AudioQueueInputRecorder>.fromOpaque(userData).release()
    }

    private static func deviceUID(for deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &uid) == noErr,
              let uid else {
            return nil
        }
        return uid.takeRetainedValue() as String
    }

    private func createNewFile() throws -> FileState {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw Self.runtimeError(code: 9, message: "Could not open file for writing")
        }
        handle.write(WavWriter.header(dataSize: 0))
        return FileState(fileHandle: handle, fileURL: url, bytesWritten: 0)
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
}
