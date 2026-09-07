import AudioToolbox
import CoreAudio
import Foundation
import os

final class AudioQueueInputRecorder: StreamingDictationRecording, StreamingDictationLatencyReporting, PausableStreamingDictationRecording {
    var onAudioBuffer: (([Float]) -> Void)?
    var onRecordingFailed: ((Error) -> Void)?
    var onLatencyEvent: ((String, Date) -> Void)?
    private let inputDevice = OSAllocatedUnfairLock<AudioObjectID?>(initialState: nil)
    var preferredInputDeviceID: AudioObjectID? {
        get { inputDevice.withLock { $0 } }
        set { inputDevice.withLock { $0 = newValue } }
    }

    private static let sampleRate: Double = 16_000
    private static let framesPerBuffer: UInt32 = 512
    private static let bufferCount = 3

    /// Native boundary permits deterministic callback/teardown tests without HAL.
    struct NativeOperations {
        var create: (UnsafePointer<AudioStreamBasicDescription>, AudioQueueInputCallback, UnsafeMutableRawPointer, UnsafeMutablePointer<AudioQueueRef?>) -> OSStatus = {
            AudioQueueNewInput($0, $1, $2, nil, nil, 0, $3)
        }
        var allocate: (AudioQueueRef, UInt32, UnsafeMutablePointer<AudioQueueBufferRef?>) -> OSStatus = {
            AudioQueueAllocateBuffer($0, $1, $2)
        }
        var enqueue: (AudioQueueRef, AudioQueueBufferRef) -> OSStatus = { AudioQueueEnqueueBuffer($0, $1, 0, nil) }
        var start: (AudioQueueRef) -> OSStatus = { AudioQueueStart($0, nil) }
        var stop: (AudioQueueRef, Bool) -> OSStatus = { AudioQueueStop($0, $1) }
        var dispose: (AudioQueueRef) -> OSStatus = { AudioQueueDispose($0, true) }
        var isRunning: (AudioQueueRef) -> Bool = {
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioQueueGetProperty($0, kAudioQueueProperty_IsRunning, &running, &size)
            return status != noErr || running != 0
        }
    }

    private let native: NativeOperations
    private let directoryName: String
    // Serializes native commands only. Neither native callbacks nor the PCM
    // processing queue acquire this lock, including during synchronous disposal.
    private let operationLock = NSRecursiveLock()
    private struct CallbackState {
        var queue: AudioQueueRef?
        var isRunning = false
        var isDraining = false
        var isPaused = false
        var generation: UInt64 = 0
        var invalidated = false
    }
    private let callbackState = OSAllocatedUnfairLock(initialState: CallbackState())
    private let stateLock = OSAllocatedUnfairLock(initialState: FileState())
    private let processingQueue = DispatchQueue(label: "com.muesli.audio-queue-input-recorder-processing")
    private let failureCallbackQueue = DispatchQueue(label: "com.muesli.audio-queue-input-recorder-failures")

    private var audioQueue: AudioQueueRef?
    private var queueCallbackUserData: UnsafeMutableRawPointer?
    private var buffers: [AudioQueueBufferRef] = []
    private var preparedInputDeviceID: AudioObjectID?
    private var isPrepared = false
    private struct FileState {
        var fileHandle: FileHandle?
        var fileURL: URL?
        var bytesWritten = 0
        var latestPowerDB: Float = -160
    }

    init(directoryName: String = "muesli-native-dictation", native: NativeOperations = NativeOperations()) {
        self.native = native
        self.directoryName = directoryName
    }

    deinit {
        cancel()
    }

    func prepare() throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !isPermanentlyInvalidated else {
            throw Self.runtimeError(code: 9, message: "Recorder was invalidated by teardown")
        }

        try prepareLocked()
        guard !isPermanentlyInvalidated else {
            disposeQueue()
            throw Self.runtimeError(code: 9, message: "Recorder was invalidated by teardown")
        }
    }

    func start() throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !isPermanentlyInvalidated else {
            throw Self.runtimeError(code: 9, message: "Recorder was invalidated by teardown")
        }

        guard !callbackState.withLock({ $0.isRunning }) else { return }
        try prepareLocked()
        guard !isPermanentlyInvalidated else {
            disposeQueue()
            throw Self.runtimeError(code: 9, message: "Recorder was invalidated by teardown")
        }

        guard let audioQueue else {
            throw Self.runtimeError(code: 1, message: "Audio queue was not initialized")
        }

        stateLock.withLock { $0 = FileState() }
        let fileState = try createNewFile()
        stateLock.withLock { $0 = fileState }
        callbackState.withLock {
            $0.isPaused = false
            $0.isDraining = false
            $0.generation &+= 1
            $0.isRunning = true
        }
        for buffer in buffers {
            let status = native.enqueue(audioQueue, buffer)
            guard status == noErr else {
                cleanupAfterStartFailure()
                throw Self.runtimeError(code: 2, message: "AudioQueueEnqueueBuffer failed: \(status)")
            }
        }
        emitLatency("audio_queue_start_begin")
        let status = native.start(audioQueue)
        emitLatency("audio_queue_start_end")
        // AudioQueueStart can block while the daemon negotiates the route, and
        // teardown may land during that window. If this instance was invalidated
        // while the call was in flight, synchronously stop what just started
        // before returning — capture must not outlive teardown.
        if isPermanentlyInvalidated {
            cleanupAfterStartFailure()
            throw Self.runtimeError(code: 9, message: "Recorder was invalidated by teardown")
        }
        guard status == noErr else {
            cleanupAfterStartFailure()
            throw Self.runtimeError(code: 3, message: "AudioQueueStart failed: \(status)")
        }
    }

    func stop() -> URL? {
        operationLock.lock()
        defer { operationLock.unlock() }
        let wasRunning = callbackState.withLock { state in
            guard state.isRunning else { return false }
            state.isRunning = false
            state.isDraining = true
            return true
        }
        guard wasRunning else { return nil }
        if let audioQueue {
            emitLatency("audio_queue_stop_begin")
            native.stop(audioQueue, false)
            // Preserve the existing bounded graceful drain for the final word.
            // Native property reads and forced stop hold no callback-state lock.
            var waitedMs = 0
            while waitedMs < 500, native.isRunning(audioQueue) {
                usleep(10_000)
                waitedMs += 10
            }
            if native.isRunning(audioQueue) { native.stop(audioQueue, true) }
            emitLatency("audio_queue_stop_end")
        }
        callbackState.withLock { $0.isDraining = false }
        emitLatency("audio_queue_processing_drain_begin")
        processingQueue.sync {}
        emitLatency("audio_queue_processing_drain_end")
        callbackState.withLock {
            $0.isPaused = false
            $0.generation &+= 1
        }
        let finalState = takeFileState()
        emitLatency("audio_queue_finalize_begin")
        let url = finalizeFile(finalState)
        emitLatency("audio_queue_finalize_end")
        return url
    }

    func cancel() {
        operationLock.lock()
        defer { operationLock.unlock() }
        disposeQueue()
        processingQueue.sync {}
        discardFile()
    }

    func currentPower() -> Float {
        stateLock.withLock { $0.latestPowerDB }
    }

    /// Terminal and synchronous: after meeting teardown, this instance must
    /// never start capture again, regardless of which queue a stale worker is
    /// on. Distinct from cancel(), which disposes but permits re-prepare.
    func invalidateForTeardown() {
        callbackState.withLock { $0.invalidated = true }
    }

    private var isPermanentlyInvalidated: Bool {
        callbackState.withLock { $0.invalidated }
    }

    func pause() {
        callbackState.withLock { if $0.isRunning { $0.isPaused = true } }
        stateLock.withLock { $0.latestPowerDB = -160 }
    }

    func resume() {
        callbackState.withLock { if $0.isRunning { $0.isPaused = false } }
    }

    private func prepareLocked() throws {
        let targetInputDeviceID = preferredInputDeviceID
        // Reuse is safe for the default route too: a queue prepared without an
        // explicit device reports kAudioQueueProperty_CurrentDevice =
        // "AQDefaultDevice", i.e. it follows the system default input at start
        // time. Explicit-device queues are bound to a fixed UID; if that device
        // disappears, AudioQueueStart fails and the caller's failure path
        // disposes + rebuilds. Neither case needs eager rebuild here.
        if isPrepared, preparedInputDeviceID == targetInputDeviceID {
            emitLatency("audio_queue_prepare_reused")
            return
        }

        guard disposeQueue() else {
            throw Self.runtimeError(code: 10, message: "Previous audio queue did not finish disposal")
        }
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
        let newInputStatus = native.create(&format, Self.inputCallback, callbackUserData, &queue)
        emitLatency("audio_queue_new_input_end")
        guard newInputStatus == noErr, let queue else {
            Self.releaseCallbackUserData(callbackUserData)
            throw Self.runtimeError(code: 4, message: "AudioQueueNewInput failed: \(newInputStatus)")
        }
        audioQueue = queue
        queueCallbackUserData = callbackUserData
        callbackState.withLock { $0.queue = queue }

        do {
            if let targetInputDeviceID {
                try applyPreferredInputDeviceID(targetInputDeviceID, to: queue)
            } else {
                emitLatency("audio_queue_preferred_input_default_route")
            }

            let bytesPerBuffer = Self.framesPerBuffer * format.mBytesPerFrame
            emitLatency("audio_queue_allocate_buffers_begin")
            for _ in 0..<Self.bufferCount {
                var buffer: AudioQueueBufferRef?
                let status = native.allocate(queue, bytesPerBuffer, &buffer)
                guard status == noErr, let buffer else {
                    throw Self.runtimeError(code: 5, message: "AudioQueueAllocateBuffer failed: \(status)")
                }
                buffers.append(buffer)
            }
            emitLatency("audio_queue_allocate_buffers_end")
        } catch {
            disposeQueue()
            throw error
        }

        preparedInputDeviceID = targetInputDeviceID
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
        let state = callbackState.withLock { $0 }
        guard state.queue == queue, state.isRunning || state.isDraining else { return }
        let draining = state.isDraining
        let generation = state.generation

        let byteCount = Int(buffer.pointee.mAudioDataByteSize)
        guard byteCount > 0 else {
            if !draining {
                native.enqueue(queue, buffer)
            }
            return
        }

        let audioData = Data(bytes: buffer.pointee.mAudioData, count: byteCount)
        // While draining, deliver but do not re-enqueue: the ring empties and
        // the queue stops itself, carrying the final partial buffer (the tail
        // of the user's last word) into the file first.
        if !draining {
            let enqueueStatus = native.enqueue(queue, buffer)
            if enqueueStatus != noErr {
                reportFailure(Self.runtimeError(code: 8, message: "AudioQueueEnqueueBuffer failed: \(enqueueStatus)"))
                return
            }
        }

        processingQueue.async { [weak self] in
            self?.processAudioData(audioData, generation: generation)
        }
    }

    private func processAudioData(_ data: Data, generation: UInt64) {
        guard callbackState.withLock({ $0.generation == generation && !$0.isPaused }) else { return }

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
        disposeQueue()
        processingQueue.sync {}
        discardFile()
    }

    private func takeFileState() -> FileState {
        stateLock.withLock { state in
            let old = state
            state = FileState()
            return old
        }
    }

    private func discardFile() {
        let state = takeFileState()
        state.fileHandle?.closeFile()
        if let url = state.fileURL { try? FileManager.default.removeItem(at: url) }
    }

    /// Caller owns operationLock, which callbacks never acquire. Publish rejection
    /// before disposal and retain callback context until native disposal succeeds.
    @discardableResult
    private func disposeQueue() -> Bool {
        callbackState.withLock {
            $0.queue = nil
            $0.isRunning = false
            $0.isDraining = false
            $0.isPaused = false
            $0.generation &+= 1
        }
        isPrepared = false
        if let audioQueue {
            native.stop(audioQueue, true)
            let status = native.dispose(audioQueue)
            guard status == noErr else {
                // Keep ownership for a later cleanup attempt; never free native
                // callback context or prepare a replacement while disposal failed.
                reportFailure(Self.runtimeError(code: 10, message: "AudioQueueDispose failed: \(status)"))
                return false
            }
        }
        let context = queueCallbackUserData
        audioQueue = nil
        queueCallbackUserData = nil
        buffers.removeAll()
        preparedInputDeviceID = nil
        Self.releaseCallbackUserData(context)
        return true
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
