import AVFoundation
import ScreenCaptureKit
import VideoToolbox
import os
import MuesliCore

/// One uninterrupted clip. All writer mutations occur on queue. Audio is the
/// meeting's existing 16 kHz cleaned mic/system feed, never another mic device.
final class ScreenVideoRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "com.muesli.screen-video", qos: .userInitiated)
    private let audio = OSAllocatedUnfairLock<MeetingVideoAudioBuffer?>(initialState: nil)
    private let collection = OSAllocatedUnfairLock<(stream: SCStream?, cutoff: CMTime?)>(initialState: (nil, nil))
    /// Close collection synchronously; writer closure waits for microphone drain.
    func requestStop(at cutoff: CMTime) {
        let capture = collection.withLock { state in
            if state.cutoff == nil { state.cutoff = cutoff }
            return state.stream
        }
        Task { if let capture { try? await capture.stopCapture() } }
    }
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var firstTime: CMTime?
    private var lastTime: CMTime?
    private var audioSamples: Int64 = 0
    private var audioTimer: DispatchSourceTimer?
    private var failure: Error?
    private var finished = false
    private var isStopping = false
    var onFinalized: (@Sendable () -> Void)?
    var onFinalizationResult: (@Sendable (Result<Double, Error>) -> Void)?
    var onFirstVideoFrame: (@Sendable (Int64) -> Void)?
    private let feedbackCapture: Bool
    private var lastSpaceCheck = Date.distantPast
    var onFailure: (@Sendable (String) -> Void)?

    // 64 kbps is unsupported by Apple's AAC encoder at 16 kHz mono.
    static let audioOutputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000
    ]

    init(url: URL, feedbackCapture: Bool = false) {
        self.url = url; self.feedbackCapture = feedbackCapture; super.init()
        if feedbackCapture { audio.withLock { $0 = MeetingVideoAudioBuffer(start: 0) } }
    }

    private func makeWriter() throws -> AVAssetWriter {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        if feedbackCapture { writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600) }
        return writer
    }

    func start(filter: SCContentFilter, width: Int, height: Int) async throws {
        let config = SCStreamConfiguration()
        config.width = max(2, width / 2 * 2)
        config.height = max(2, height / 2 * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.queueDepth = 3
        config.showsCursor = true
        config.capturesAudio = false
        try prepareWriter(width: config.width, height: config.height)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        let admitted = collection.withLock { state in
            guard state.cutoff == nil else { return false }
            state.stream = stream; return true
        }
        guard admitted else { throw CancellationError() }
        try await stream.startCapture()
        if collection.withLock({ $0.cutoff != nil }) { try? await stream.stopCapture() }
    }

    func prepareWriter(width: Int, height: Int) throws {
        let writer = try makeWriter()
        let codec: AVVideoCodecType = Self.hasHardwareEncoder(kCMVideoCodecType_HEVC) ? .hevc : .h264
        guard Self.hasHardwareEncoder(codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264) else {
            throw Self.error("A hardware video encoder is unavailable.")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000,
                AVVideoMaxKeyFrameIntervalKey: 30, AVVideoAllowFrameReorderingKey: false]
        ])
        input.expectsMediaDataInRealTime = true
        let sound = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioOutputSettings)
        sound.expectsMediaDataInRealTime = true
        guard writer.canAdd(input), writer.canAdd(sound) else { throw Self.error("Cannot prepare the video writer.") }
        writer.add(input); writer.add(sound)
        self.writer = writer; videoInput = input; audioInput = sound
    }

    /// Feed a synthetic native frame through the production writer queue, without a screen stream.
    func testing_appendVideoFrame(_ sample: CMSampleBuffer) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                self.appendVideoFrame(sample)
                continuation.resume(returning: self.firstTime != nil)
            }
        }
    }

    func appendAudio(_ samples: [Int16], microphone: Bool, startFrame: Int64) {
        let overflow = audio.withLock { mix in
            if feedbackCapture && microphone {
                if mix?.appendFeedbackMicrophone(samples, start: startFrame) == false {
                    mix = nil; return true
                }
            } else { mix?.append(samples, start: startFrame, microphone: microphone) }
            return false
        }
        if overflow { queue.async { self.fail(Self.error("Audio encoding fell behind.")) } }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            if !self.collection.withLock({ $0.cutoff != nil }) { self.fail(error) }
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !isStopping, !finished, failure == nil, CMSampleBufferIsValid(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              writer != nil, videoInput != nil else { return }
        appendVideoFrame(sampleBuffer)
    }
    private func appendVideoFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let writer, let input = videoInput else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard !finished, !isStopping, collection.withLock({ $0.cutoff.map { time <= $0 } ?? true }) else { return }
        if firstTime == nil {
            guard writer.status == .writing || writer.startWriting() else { fail(writer.error ?? Self.error("Cannot start video writing.")); return }
            guard input.isReadyForMoreMediaData else { return }
            writer.startSession(atSourceTime: time)
            firstTime = time
            audio.withLock {
                let frame = Int64((CMTimeGetSeconds(time) * 16_000).rounded())
                if feedbackCapture { $0?.discard(before: frame) }
                else { $0 = MeetingVideoAudioBuffer(start: frame) }
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.writeAudio() }
            audioTimer = timer; timer.resume()
        }
        if input.isReadyForMoreMediaData {
            guard input.append(sampleBuffer) else { fail(writer.error ?? Self.error("Video write failed.")); return }
            if lastTime == nil { onFirstVideoFrame?(Int64((CMTimeGetSeconds(time) * 16_000).rounded())) }
            lastTime = time
        }
        if let lastTime, CMTimeGetSeconds(time - lastTime) > 5 { fail(Self.error("The video encoder could not keep up.")) }
    }

    private func writeAudio(at hostTime: CMTime = CMClockGetTime(CMClockGetHostTimeClock()), flush: Bool = false, targetOverride: Int64? = nil) {
        guard !finished, failure == nil, let start = firstTime, let input = audioInput else { return }
        if Date().timeIntervalSince(lastSpaceCheck) > 5 {
            lastSpaceCheck = Date()
            let free = ((try? FileManager.default.attributesOfFileSystem(forPath: url.deletingLastPathComponent().path)[.systemFreeSize]) as? NSNumber)?.int64Value ?? 0
            guard free > 2_000_000_000 else { fail(Self.error("Screen recording stopped: disk space is low.")); return }
        }
        let admittedTime = collection.withLock { $0.cutoff.map { CMTimeMinimum(hostTime, $0) } ?? hostTime }
        let elapsed = max(0, CMTimeGetSeconds(admittedTime - start))
        // Meeting AEC can retain three seconds. Feedback has serial mic delivery:
        // consume only through received input, so queue latency cannot erase PCM.
        // Feedback bounds actual queued PCM at admission, rather than silent time.
        let clockTarget = targetOverride ?? Int64(max(0, elapsed - (flush || feedbackCapture ? 0 : 3.5)) * 16_000)
        guard feedbackCapture || clockTarget - audioSamples <= 160_000 else { fail(Self.error("Audio encoding fell behind.")); return }
        let target: Int64
        if feedbackCapture && !flush {
            let delivered = audio.withLock { mix in
                mix.map { max(0, ($0.microphoneEndFrame ?? $0.cursor) - $0.cursor) } ?? 0
            }
            target = min(clockTarget, audioSamples + delivered)
        } else { target = clockTarget }
        while (flush ? target > audioSamples : target - audioSamples >= 1600) && input.isReadyForMoreMediaData {
            let count = Int(min(1600, target - audioSamples))
            let mixed = audio.withLock { $0?.take(count: count) ?? [Int16](repeating: 0, count: count) }
            do {
                let buffer = try Self.audioBuffer(mixed, time: start + CMTime(value: audioSamples, timescale: 16_000))
                guard input.append(buffer) else { throw writer?.error ?? Self.error("Audio write failed.") }
                audioSamples += Int64(count)
            } catch { fail(error); return }
        }
    }

    private static func audioBuffer(_ samples: [Int16], time: CMTime) throws -> CMSampleBuffer {
        var format = AudioStreamBasicDescription(mSampleRate: 16_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description) == noErr, let description else { throw error("Invalid audio format.") }
        var block: CMBlockBuffer?
        let count = samples.count * 2
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: count, flags: 0, blockBufferOut: &block) == noErr, let block else { throw error("Audio allocation failed.") }
        let copied = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: count) }
        guard copied == noErr else { throw error("Audio copy failed.") }
        var result: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
            dataBuffer: block, formatDescription: description, sampleCount: samples.count,
            presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &result) == noErr,
              let result else { throw error("Audio sample creation failed.") }
        return result
    }

    func stop(timeout: TimeInterval = 8) async throws -> Double {
        let capture = collection.withLock { $0.stream }
        return try await withCheckedThrowingContinuation { continuation in
            let completion = OSAllocatedUnfairLock<CheckedContinuation<Double, Error>?>(initialState: continuation)
            let complete: @Sendable (Result<Double, Error>) -> Void = { result in
                completion.withLock { value -> CheckedContinuation<Double, Error>? in
                    let pending = value; value = nil; return pending
                }?.resume(with: result)
            }
            // The timeout releases only the UI waiter. Keep the writer and its
            // ownership journal alive until Apple's completion callback arrives.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                complete(.failure(Self.error("Screen finalization is continuing in the background.")))
            }
            let finalized: @Sendable (Result<Double, Error>) -> Void = { [self] result in
                onFinalizationResult?(result)
                onFinalized?()
                complete(result)
            }
            // Retiring capture must not gate finalizing the frames already received.
            Task { if let capture { try? await capture.stopCapture() } }
            queue.async {
                self.isStopping = true
                self.collection.withLock { $0.stream = nil }
                self.audioTimer?.cancel(); self.audioTimer = nil
                guard !self.finished else { finalized(.failure(Self.error("Recording already finalized."))); return }
                guard let start = self.firstTime else {
                    self.writer?.cancelWriting()
                    finalized(.failure(self.failure ?? Self.error("No screen frames were captured."))); return
                }
                let end = self.collection.withLock { $0.cutoff } ?? CMClockGetTime(CMClockGetHostTimeClock())
                let target = Int64(max(0, CMTimeGetSeconds(end - start)) * 16_000)
                self.drainAndFinish(target: target, start: start, deadline: .now() + .seconds(2), complete: finalized)
            }
        }
    }
    private func drainAndFinish(target: Int64, start: CMTime, deadline: DispatchTime, complete: @escaping @Sendable (Result<Double, Error>) -> Void) {
        guard !finished else { return }
        guard let writer, writer.status == .writing else {
            complete(.failure(writer?.error ?? Self.error("Video writer stopped."))); return
        }
        writeAudio(flush: true, targetOverride: target)
        if failure == nil, target > audioSamples, DispatchTime.now() < deadline {
            queue.asyncAfter(deadline: .now() + .milliseconds(10)) {
                self.drainAndFinish(target: target, start: start, deadline: deadline, complete: complete)
            }
            return
        }
        // Backpressure must not prevent finalization forever. After the bounded
        // drain window, preserve encoded media even if the audio tail is incomplete.
        let incompleteAudio = failure == nil && target > audioSamples
        let finalizationError = failure ?? (feedbackCapture && incompleteAudio
            ? Self.error("Narration encoding is incomplete. The complete WAV narration is retained.") : nil)
        if incompleteAudio {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.muesli", category: "MeetingVideo")
                .warning("Audio drain timed out; finalizing encoded media without the remaining audio tail.")
        }
        finished = true
        audio.withLock { $0 = nil }
        if feedbackCapture, let cutoff = collection.withLock({ $0.cutoff }), cutoff > start {
            writer.endSession(atSourceTime: cutoff)
        }
        videoInput?.markAsFinished(); audioInput?.markAsFinished()
        let duration = feedbackCapture ? Double(target) / 16_000
            : max(Double(audioSamples) / 16_000, CMTimeGetSeconds((lastTime ?? start) - start))
        writer.finishWriting {
            if writer.status == .completed {
                if let finalizationError { complete(.failure(finalizationError)) }
                else { complete(.success(duration)) }
            } else { complete(.failure(writer.error ?? Self.error("Could not finalize screen recording."))) }
        }
    }
    private func fail(_ error: Error) {
        guard failure == nil else { return }
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.muesli", category: "MeetingVideo").error("Encoding failed: \(String(describing: error as NSError), privacy: .public)")
        failure = error; audio.withLock { $0 = nil }
        onFailure?(error.localizedDescription)
    }
    static func hasHardwareEncoder(_ codec: CMVideoCodecType) -> Bool {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr, let values = list as? [[String: Any]] else { return false }
        return values.contains {
            ($0[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value == codec
                && ($0[kVTVideoEncoderList_IsHardwareAccelerated as String] as? NSNumber)?.boolValue == true
        }
    }
    static func error(_ message: String) -> NSError {
        NSError(domain: "ScreenRecording", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

final class ScreenAudioRouter: @unchecked Sendable {
    private let recorder = OSAllocatedUnfairLock<ScreenVideoRecorder?>(initialState: nil)
    func set(_ value: ScreenVideoRecorder?) { recorder.withLock { $0 = value } }
    func append(_ samples: [Int16], microphone: Bool, startFrame: Int64) {
        recorder.withLock { $0 }?.appendAudio(samples, microphone: microphone, startFrame: startFrame)
    }
}
