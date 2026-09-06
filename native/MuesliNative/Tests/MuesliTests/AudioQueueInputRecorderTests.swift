import AudioToolbox
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("AudioQueue callback lifetime")
struct AudioQueueInputRecorderTests {
    @Test("startup failure or invalidation disposes without blocking native callbacks", arguments: [false, true])
    func startupCleanup(invalidate: Bool) throws {
        let driver = CallbackQueueDriver()
        var operations = driver.operations
        weak var owner: AudioQueueInputRecorder?
        operations.start = { _ in
            if invalidate { owner?.invalidateForTeardown() }
            return invalidate ? noErr : -50
        }
        let recorder = AudioQueueInputRecorder(native: operations)
        owner = recorder
        #expect(throws: Error.self) { try recorder.start() }
        driver.callbacks.wait()
        #expect(driver.disposals == 1)
        #expect(driver.enqueueCalls == 3) // Teardown callbacks must not re-enqueue.
        recorder.cancel()
        #expect(driver.disposals == 1)
    }

    @Test("failed disposal retains ownership and prevents a replacement queue")
    func failedDisposal() throws {
        let driver = CallbackQueueDriver()
        let recorder = AudioQueueInputRecorder(native: driver.operations)
        try recorder.start()
        driver.rejectDisposal = true
        recorder.cancel()
        #expect(throws: Error.self) { try recorder.prepare() }
        #expect(driver.creations == 1)
        driver.rejectDisposal = false
        recorder.cancel()
        try recorder.prepare()
        #expect(driver.creations == 2)
        recorder.cancel()
    }

    @Test("native callback context retains its owner until explicit disposal finishes")
    func callbackOwnerLifetime() throws {
        let driver = CallbackQueueDriver()
        weak var released: AudioQueueInputRecorder?
        do {
            let recorder = AudioQueueInputRecorder(native: driver.operations)
            released = recorder
            try recorder.prepare()
        }
        #expect(released != nil)
        released?.cancel()
        #expect(released == nil)
        #expect(driver.disposals == 1)
    }

    @Test("graceful stop delivers its final buffer before finalizing the file")
    func stopPreservesTail() throws {
        let driver = CallbackQueueDriver()
        let recorder = AudioQueueInputRecorder(native: driver.operations)
        try recorder.start()
        let url = try #require(recorder.stop())
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        #expect(data.count == 46) // WAV header plus the callback's one Int16 sample.
        #expect(driver.enqueueCalls == 3)
        recorder.cancel()
        #expect(driver.disposals == 1)
    }
}

/// stop/dispose synchronously wait for a callback delivered on another thread,
/// as native AudioQueue disposal did in the captured failure. Buffers and user
/// data stay valid until all callbacks finish; no real audio device is opened.
private final class CallbackQueueDriver: @unchecked Sendable {
    let queue = AudioQueueRef(bitPattern: 1)!
    let callbacks = DispatchGroup()
    var callback: AudioQueueInputCallback?
    var userData: UnsafeMutableRawPointer?
    var buffers: [AudioQueueBufferRef] = []
    var enqueueCalls = 0
    var disposals = 0
    var creations = 0
    var rejectDisposal = false

    var operations: AudioQueueInputRecorder.NativeOperations {
        var result = AudioQueueInputRecorder.NativeOperations()
        result.create = { [self] _, callback, userData, output in
            creations += 1
            self.callback = callback
            self.userData = userData
            output.pointee = queue
            return noErr
        }
        result.allocate = { [self] _, _, output in
            let data = UnsafeMutableRawPointer.allocate(byteCount: 4, alignment: 4)
            data.storeBytes(of: Float(0.25), as: Float.self)
            let buffer = AudioQueueBufferRef.allocate(capacity: 1)
            buffer.initialize(to: AudioQueueBuffer(mAudioDataBytesCapacity: 4, mAudioData: data,
                mAudioDataByteSize: 4, mUserData: nil, mPacketDescriptionCapacity: 0,
                mPacketDescriptions: nil, mPacketDescriptionCount: 0))
            buffers.append(buffer)
            output.pointee = buffer
            return noErr
        }
        result.enqueue = { [self] _, _ in enqueueCalls += 1; return noErr }
        result.start = { _ in noErr }
        result.stop = { [self] _, _ in deliverAndWait(); return noErr }
        result.dispose = { [self] _ in
            disposals += 1
            deliverAndWait()
            return rejectDisposal ? -50 : noErr
        }
        result.isRunning = { _ in false }
        return result
    }

    private func deliverAndWait() {
        guard let callback, let buffer = buffers.first else { return }
        let done = DispatchSemaphore(value: 0)
        callbacks.enter()
        // A native callback has its own thread; do not compete for the global
        // worker pool that the full test suite can occupy with synchronous waits.
        Thread.detachNewThread { [self] in
            var timestamp = AudioTimeStamp()
            callback(userData, queue, buffer, &timestamp, 0, nil)
            done.signal()
            callbacks.leave()
        }
        #expect(done.wait(timeout: .now() + 1) == .success)
    }

    deinit {
        for buffer in buffers {
            buffer.pointee.mAudioData.deallocate()
            buffer.deinitialize(count: 1)
            buffer.deallocate()
        }
    }
}
