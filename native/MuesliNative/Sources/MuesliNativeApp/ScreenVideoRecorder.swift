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
    private var stream: SCStream?
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
    private var lastSpaceCheck = Date.distantPast
    var onFailure: (@Sendable (String) -> Void)?

    // 64 kbps is unsupported by Apple's AAC encoder at 16 kHz mono.
    static let audioOutputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000
    ]

    init(url: URL) { self.url = url; super.init() }

    func start(filter: SCContentFilter, width: Int, height: Int) async throws {
        let config = SCStreamConfiguration()
        config.width = max(2, width / 2 * 2)
        config.height = max(2, height / 2 * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.queueDepth = 3
        config.showsCursor = true
        config.capturesAudio = false
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let codec: AVVideoCodecType = Self.hasHardwareEncoder(kCMVideoCodecType_HEVC) ? .hevc : .h264
        guard Self.hasHardwareEncoder(codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264) else {
            throw Self.error("A hardware video encoder is unavailable.")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: config.width, AVVideoHeightKey: config.height,
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
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    func appendAudio(_ samples: [Int16], microphone: Bool, startFrame: Int64) {
        audio.withLock { $0?.append(samples, start: startFrame, microphone: microphone) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.fail(error) }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !isStopping, !finished, failure == nil, CMSampleBufferIsValid(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let writer, let input = videoInput else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstTime == nil {
            guard writer.startWriting() else { fail(writer.error ?? Self.error("Cannot start video writing.")); return }
            writer.startSession(atSourceTime: time)
            firstTime = time
            audio.withLock { $0 = MeetingVideoAudioBuffer(start: Int64((CMTimeGetSeconds(time) * 16_000).rounded())) }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.writeAudio() }
            audioTimer = timer; timer.resume()
        }
        if input.isReadyForMoreMediaData {
            guard input.append(sampleBuffer) else { fail(writer.error ?? Self.error("Video write failed.")); return }
            lastTime = time
        }
        if let lastTime, CMTimeGetSeconds(time - lastTime) > 5 { fail(Self.error("The video encoder could not keep up.")) }
    }

    private func writeAudio(flush: Bool = false, targetOverride: Int64? = nil) {
        guard !finished, failure == nil, let start = firstTime, let input = audioInput else { return }
        if Date().timeIntervalSince(lastSpaceCheck) > 5 {
            lastSpaceCheck = Date()
            let free = ((try? FileManager.default.attributesOfFileSystem(forPath: url.deletingLastPathComponent().path)[.systemFreeSize]) as? NSNumber)?.int64Value ?? 0
            guard free > 2_000_000_000 else { fail(Self.error("Screen recording stopped: disk space is low.")); return }
        }
        let elapsed = max(0, CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()) - start))
        // AEC can retain up to three seconds awaiting a reference. Delay encoding,
        // not presentation timestamps; late output still occupies its capture position.
        let target = targetOverride ?? Int64(max(0, elapsed - (flush ? 0 : 3.5)) * 16_000)
        guard target - audioSamples <= 160_000 else { fail(Self.error("Audio encoding fell behind.")); return }
        while target - audioSamples >= 1600 && input.isReadyForMoreMediaData {
            let mixed = audio.withLock { $0?.take(count: 1600) ?? [Int16](repeating: 0, count: 1600) }
            do {
                let buffer = try Self.audioBuffer(mixed, time: start + CMTime(value: audioSamples, timescale: 16_000))
                guard input.append(buffer) else { throw writer?.error ?? Self.error("Audio write failed.") }
                audioSamples += 1600
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
        let capture = stream
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
                onFinalized?()
                complete(result)
            }
            // Retiring capture must not gate finalizing the frames already received.
            Task { if let capture { try? await capture.stopCapture() } }
            queue.async {
                self.isStopping = true
                self.stream = nil
                self.audioTimer?.cancel(); self.audioTimer = nil
                guard !self.finished else { finalized(.failure(Self.error("Recording already finalized."))); return }
                guard let start = self.firstTime else {
                    self.writer?.cancelWriting()
                    finalized(.failure(self.failure ?? Self.error("No screen frames were captured."))); return
                }
                let target = Int64(max(0, CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()) - start)) * 16_000)
                self.drainAndFinish(target: target, start: start, complete: finalized)
            }
        }
    }
    private func drainAndFinish(target: Int64, start: CMTime, complete: @escaping @Sendable (Result<Double, Error>) -> Void) {
        guard !finished else { return }
        guard let writer, writer.status == .writing else {
            complete(.failure(writer?.error ?? Self.error("Video writer stopped."))); return
        }
        writeAudio(flush: true, targetOverride: target)
        if failure == nil, target - audioSamples >= 1600 {
            queue.asyncAfter(deadline: .now() + .milliseconds(10)) {
                self.drainAndFinish(target: target, start: start, complete: complete)
            }
            return
        }
        finished = true
        audio.withLock { $0 = nil }
        videoInput?.markAsFinished(); audioInput?.markAsFinished()
        let duration = max(Double(audioSamples) / 16_000, CMTimeGetSeconds((lastTime ?? start) - start))
        writer.finishWriting {
            if writer.status == .completed { complete(.success(duration)) }
            else { complete(.failure(writer.error ?? Self.error("Could not finalize screen recording."))) }
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
