import AVFoundation
import Foundation
import ScreenCaptureKit
import MuesliCore
import os

final class SystemAudioRecorder: NSObject, SCStreamOutput, SystemAudioCapturing, SystemAudioDiagnosticsProviding {
    var onPCMSamples: (([Int16]) -> Void)?

    private var stream: SCStream?
    private var outputFile: FileHandle?
    private var outputURL: URL?
    private var totalBytesWritten = 0
    private(set) var isRecording = false
    private(set) var isPaused = false

    private static let sampleRate: Double = 16_000
    private static let channels: Int = 1
    private let diagnosticsLock = OSAllocatedUnfairLock(initialState: DiagnosticsState())

    private struct DiagnosticsState {
        var callbackCount = 0
        var bufferCount = 0
        var emptyBufferCount = 0
        var unsupportedFormatCount = 0
        var inputByteCount = 0
        var bytesWritten = 0
        var sourceSampleRate: Double = 0
        var sourceChannels: UInt32 = 0
        var preConversion = AudioSampleStats()
        var postConversion = AudioSampleStats()
    }

    var diagnosticsSnapshot: SystemAudioCaptureDiagnosticsSnapshot {
        diagnosticsLock.withLock { state in
            SystemAudioCaptureDiagnosticsSnapshot(
                backend: "ScreenCaptureKit",
                callbackCount: state.callbackCount,
                bufferCount: state.bufferCount,
                emptyBufferCount: state.emptyBufferCount,
                unsupportedFormatCount: state.unsupportedFormatCount,
                inputByteCount: state.inputByteCount,
                bytesWritten: state.bytesWritten,
                sourceSampleRate: state.sourceSampleRate,
                sourceChannels: state.sourceChannels,
                preConversion: state.preConversion.snapshot(),
                postConversion: state.postConversion.snapshot()
            )
        }
    }

    override init() {
        super.init()
    }

    func start() async throws {
        guard !isRecording else { return }

        // Create output WAV file
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-system-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let url = outputDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let file = FileHandle(forWritingAtPath: url.path) else {
            throw NSError(domain: "SystemAudio", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not open output file",
            ])
        }
        file.write(WavWriter.header(dataSize: 0))
        outputFile = file
        outputURL = url
        totalBytesWritten = 0
        isRecording = true
        isPaused = false

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    guard let self else { return }
                    try await self.startStream()
                    fputs("[system-audio] SCStream capture started\n", stderr)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    throw NSError(domain: "SystemAudio", code: 3, userInfo: [
                        NSLocalizedDescriptionKey: "Timed out while starting system audio capture",
                    ])
                }

                guard let _ = try await group.next() else {
                    throw NSError(domain: "SystemAudio", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: "System audio startup ended unexpectedly",
                    ])
                }
                group.cancelAll()
            }
        } catch {
            fputs("[system-audio] SCStream start failed: \(error)\n", stderr)
            cleanupFailedStart()
            throw error
        }
    }

    func stop() -> URL? {
        guard isRecording || outputFile != nil || outputURL != nil else { return nil }
        isRecording = false
        isPaused = false
        onPCMSamples = nil

        if let stream {
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                try? await stream.stopCapture()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 3)
        }
        stream = nil

        // Finalize WAV
        if let outputFile {
            let header = WavWriter.header(dataSize: totalBytesWritten)
            outputFile.seek(toFileOffset: 0)
            outputFile.write(header)
            outputFile.closeFile()
        }
        outputFile = nil
        let writtenBytes = totalBytesWritten
        let completedURL = outputURL
        outputURL = nil
        totalBytesWritten = 0

        fputs("[system-audio] capture stopped, \(writtenBytes) bytes written\n", stderr)
        return completedURL
    }

    func pause() {
        guard isRecording else { return }
        isPaused = true
    }

    func resume() {
        guard isRecording else { return }
        isPaused = false
    }

    // MARK: - SCStream setup

    private func startStream() async throws {
        // Get shareable content (required to create a filter)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        // Create a filter that captures all audio — use a display filter with audio only
        guard let display = content.displays.first else {
            throw NSError(domain: "SystemAudio", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No display found for SCStream",
            ])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        // Audio-only: disable video capture
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps minimum (can't set 0)
        config.showsCursor = false

        // Audio configuration
        config.capturesAudio = true
        config.sampleRate = Int(Self.sampleRate)
        config.channelCount = Self.channels
        config.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.muesli.system-audio"))
        try await stream.startCapture()
        self.stream = stream
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, isRecording, !isPaused else { return }
        diagnosticsLock.withLock { $0.callbackCount += 1 }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            diagnosticsLock.withLock { $0.emptyBufferCount += 1 }
            return
        }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else {
            diagnosticsLock.withLock { $0.emptyBufferCount += 1 }
            return
        }

        // Get the audio format
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else { return }
        diagnosticsLock.withLock { state in
            state.bufferCount += 1
            state.inputByteCount += length
            state.sourceSampleRate = asbd.mSampleRate
            state.sourceChannels = asbd.mChannelsPerFrame
        }

        // Extract raw audio bytes
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let dataPointer else { return }

        // Convert float32 samples to int16 PCM for WAV
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            let floatCount = length / MemoryLayout<Float>.size
            let floatPointer = UnsafeRawPointer(dataPointer).bindMemory(to: Float.self, capacity: floatCount)

            // If stereo, mix down to mono
            let outputSamples: Int
            if Int(asbd.mChannelsPerFrame) > 1 {
                let channelCount = Int(asbd.mChannelsPerFrame)
                outputSamples = floatCount / channelCount
            } else {
                outputSamples = floatCount
            }

            var int16Data = Data(count: outputSamples * 2)
            var preConversion = [Float]()
            preConversion.reserveCapacity(outputSamples)
            int16Data.withUnsafeMutableBytes { rawBuffer in
                let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
                let channels = Int(asbd.mChannelsPerFrame)
                for i in 0..<outputSamples {
                    var sample: Float
                    if channels > 1 {
                        // Average channels for mono mixdown
                        var sum: Float = 0
                        for ch in 0..<channels {
                            sum += floatPointer[i * channels + ch]
                        }
                        sample = sum / Float(channels)
                    } else {
                        sample = floatPointer[i]
                    }
                    preConversion.append(sample)
                    // Clamp and convert to int16
                    let clamped = max(-1.0, min(1.0, sample))
                    int16Buffer[i] = Int16(clamped * 32767.0)
                }
            }
            let int16Samples = int16Data.withUnsafeBytes { rawBuffer in
                Array(rawBuffer.bindMemory(to: Int16.self))
            }
            let bytesToWrite = int16Data.count
            let preConversionSamples = preConversion

            outputFile?.write(int16Data)
            totalBytesWritten += bytesToWrite
            diagnosticsLock.withLock { state in
                state.bytesWritten += bytesToWrite
                state.preConversion.addFloats(preConversionSamples)
                state.postConversion.addInt16(int16Samples)
            }
            onPCMSamples?(int16Samples)
        } else {
            guard asbd.mFormatID == kAudioFormatLinearPCM,
                  asbd.mBitsPerChannel == 16,
                  abs(asbd.mSampleRate - Self.sampleRate) < 1.0,
                  (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
            else {
                diagnosticsLock.withLock { $0.unsupportedFormatCount += 1 }
                fputs("[system-audio] unsupported SCStream integer PCM format rate=\(asbd.mSampleRate) channels=\(asbd.mChannelsPerFrame) bits=\(asbd.mBitsPerChannel) flags=\(asbd.mFormatFlags)\n", stderr)
                return
            }

            let rawData = Data(bytes: dataPointer, count: length)
            let interleavedSamples = rawData.withUnsafeBytes { rawBuffer in
                Array(rawBuffer.bindMemory(to: Int16.self))
            }
            let channels = max(Int(asbd.mChannelsPerFrame), 1)
            let int16Samples: [Int16]
            if channels == 1 {
                int16Samples = interleavedSamples
            } else {
                let frameCount = interleavedSamples.count / channels
                int16Samples = (0..<frameCount).map { frame in
                    var sum = 0
                    for channel in 0..<channels {
                        sum += Int(interleavedSamples[frame * channels + channel])
                    }
                    return Int16(clamping: sum / channels)
                }
            }
            let int16Data = int16Samples.withUnsafeBufferPointer { Data(buffer: $0) }
            outputFile?.write(int16Data)
            totalBytesWritten += int16Data.count
            diagnosticsLock.withLock { state in
                state.bytesWritten += int16Data.count
                state.preConversion.addInt16(interleavedSamples)
                state.postConversion.addInt16(int16Samples)
            }
            onPCMSamples?(int16Samples)
        }
    }

    private func cleanupFailedStart() {
        isRecording = false
        isPaused = false
        stream = nil
        onPCMSamples = nil

        if let outputFile {
            outputFile.closeFile()
        }
        outputFile = nil

        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
        totalBytesWritten = 0
    }
}
