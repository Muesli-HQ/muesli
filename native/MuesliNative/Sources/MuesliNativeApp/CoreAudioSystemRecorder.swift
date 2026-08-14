import AppKit
import Atomics
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import MuesliCore
import os

/// Protocol for system audio capture backends (ScreenCaptureKit vs CoreAudio tap).
protocol SystemAudioCapturing: AnyObject {
    var onPCMSamples: (([Int16]) -> Void)? { get set }
    var isRecording: Bool { get }
    var isPaused: Bool { get }
    func start() async throws
    func pause()
    func resume()
    func stop() -> URL?

    /// Monotonic liveness counter advanced by every IO callback while
    /// capturing. A stall while recording means the capture graph is dead even
    /// if every API reports success. Backends without a heartbeat (the SCK
    /// fallback) return 0 and are exempt from stall monitoring.
    var captureHeartbeat: UInt64 { get }
    /// Fired when a route-change rebuild fails permanently (all retries
    /// exhausted). Capture is dead from this point unless a later route change
    /// or recovery attempt succeeds.
    var onCaptureFailure: ((Error) -> Void)? { get set }
    /// True while a route-change/health rebuild (including retries) is in
    /// flight; the watchdog treats this as a known-transient stall window.
    var isRebuilding: Bool { get }
    /// Whether this backend advances captureHeartbeat during capture. Backends
    /// without a heartbeat (SCK) must be excluded from stall monitoring.
    var supportsHeartbeatMonitoring: Bool { get }
    /// True while a route transition is still settling (recent notification).
    /// The watchdog skips stall evaluation in this window: the old tap's
    /// heartbeat stalling mid-transition is expected, not a dead graph.
    var isRouteSettling: Bool { get }
    /// Health-driven rebuild: tear down and recreate the capture graph with
    /// the same bounded retry policy used for route changes. Returns whether a
    /// rebuild was actually started. Default no-op (false) for backends without
    /// a rebuild path.
    @discardableResult
    func rebuildForHealthRecovery(reason: String) -> Bool
}

extension SystemAudioCapturing {
    var captureHeartbeat: UInt64 { 0 }
    var isRebuilding: Bool { false }
    var supportsHeartbeatMonitoring: Bool { false }
    var isRouteSettling: Bool { false }
    var onCaptureFailure: ((Error) -> Void)? {
        get { nil }
        set {}
    }
    func rebuildForHealthRecovery(reason: String) -> Bool { false }
}

/// Bounded backoff for tap rebuilds after route-change/health failures.
/// The observed failure mode (tapCreationFailed mid-route-churn) is transient
/// but Bluetooth transitions take seconds to settle on the daemon, so the
/// schedule is deliberately sparse; after the schedule is exhausted the
/// failure is terminal for this episode (the watchdog's slower cooldown
/// retries continue past it).
struct RebuildRetryPolicy: Equatable {
    let delays: [TimeInterval]

    static let `default` = RebuildRetryPolicy(delays: [2, 5])

    /// Delay before the next attempt after `failures` consecutive failures,
    /// or nil when the budget is exhausted.
    func nextDelay(afterFailures failures: Int) -> TimeInterval? {
        failures < delays.count ? delays[failures] : nil
    }
}

/// Captures system audio via CoreAudio process tap + aggregate device.
///
/// Replaces `SystemAudioRecorder` (ScreenCaptureKit) for meeting system audio capture.
/// Key advantages:
/// - No conflict with `CGWindowListCreateImage` (screenshot OCR works during meetings)
/// - Doesn't require "Screen & System Audio Recording" permission for audio capture
/// - Hardware-synchronized with mic input when used in an aggregate device
final class CoreAudioSystemRecorder: SystemAudioCapturing, SystemAudioDiagnosticsProviding {
    var onPCMSamples: (([Int16]) -> Void)?

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var deviceIOProcID: AudioDeviceIOProcID?
    private var deviceIOBlock: AudioDeviceIOBlock?
    private let deviceIOQueue = DispatchQueue(label: "com.muesli.system-audio-tap.io", qos: .userInitiated)
    private let processingQueue = DispatchQueue(label: "com.muesli.system-audio-tap")
    private var defaultOutputDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    private var outputFile: FileHandle?
    private var outputURL: URL?
    private var totalBytesWritten = 0
    private var activeCaptureGeneration: UInt64 = 0
    private let recordingFlag = ManagedAtomic(false)
    private let pausedFlag = ManagedAtomic(false)
    /// Monotonic liveness counter: advanced by every IO callback while
    /// capturing. A stall while isRecording && !isPaused means the capture
    /// graph is dead even when every CoreAudio call reported success.
    private let heartbeatCounter = ManagedAtomic<UInt64>(0)
    var captureHeartbeat: UInt64 { heartbeatCounter.load(ordering: .relaxed) }
    /// Fired when a route-change/health rebuild exhausts its retry budget and
    /// capture is dead. Bridged to episode telemetry by MeetingSession.
    var onCaptureFailure: ((Error) -> Void)?
    /// True while a route-change/health rebuild (including retries) is in
    /// flight; the watchdog treats this as a known-transient stall window.
    private(set) var isRebuilding = false
    var supportsHeartbeatMonitoring: Bool { true }
    /// Set when a rebuild exhausts its retry budget. The recorder deliberately
    /// keeps isRecording/onPCMSamples alive in that state so the watchdog can
    /// drive a later health-recovery rebuild — flipping them would make the
    /// terminal state unrecoverable by construction.
    private let captureDeadFlag = ManagedAtomic(false)
    var captureIsDead: Bool { captureDeadFlag.load(ordering: .relaxed) }
    private var rebuildRetryWorkItem: DispatchWorkItem?
    private var rebuildRetryCount = 0
    /// Backoff after the initial failure: sparse, because BT route churn takes
    /// seconds to settle on the daemon (measured live).
    /// (var so tests can inject a fast schedule)
    static var rebuildRetryPolicy = RebuildRetryPolicy.default
    /// Settle debounce for route-change rebuilds: how long after the last
    /// route notification before the rebuild fires.
    static var routeSettleDelay: TimeInterval = 1.5
    /// Last default-output route notification (ms since epoch; 0 = never).
    /// Read across queues via atomics; written from processingQueue.
    private let lastRouteChangeAtMs = ManagedAtomic<Int64>(0)
    /// True while a route transition is still settling (recent notification).
    /// The watchdog skips stall evaluation in this window: the old tap's
    /// heartbeat stalling mid-transition is expected, not a dead graph.
    var isRouteSettling: Bool {
        let lastRoute = lastRouteChangeAtMs.load(ordering: .relaxed)
        guard lastRoute != 0 else { return false }
        let elapsedMs = Date().timeIntervalSince1970 * 1000 - Double(lastRoute)
        return elapsedMs < (Self.routeSettleDelay * 1000 + 2000)
    }
    /// Test seam for the rebuild path (HAL create+start is not unit-testable).
    var createAndStartForTesting: (() throws -> Void)?
    private(set) var isRecording: Bool {
        get { recordingFlag.load(ordering: .acquiring) }
        set { recordingFlag.store(newValue, ordering: .releasing) }
    }
    private(set) var isPaused: Bool {
        get { pausedFlag.load(ordering: .acquiring) }
        set { pausedFlag.store(newValue, ordering: .releasing) }
    }

    private static let targetSampleRate: Double = 16_000

    /// Source format from the tap (queried at setup time).
    private var sourceSampleRate: Double = 48_000
    private var sourceChannels: UInt32 = 2
    private var sourceFormat = AudioStreamBasicDescription()
    private var resampler: AVAudioConverter?
    private var resamplerInputFormat: AVAudioFormat?
    private var resamplerOutputFormat: AVAudioFormat?
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
                backend: "CoreAudioTapIOProc",
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

    deinit {
        if isRecording
            || outputFile != nil
            || aggregateDeviceID != kAudioObjectUnknown
            || tapID != kAudioObjectUnknown
        {
            _ = stop()
        }
    }

    func start() async throws {
        guard !isRecording else { return }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-system-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let file = FileHandle(forWritingAtPath: url.path) else {
            throw RecorderError.fileCreationFailed
        }
        file.write(WavWriter.header(dataSize: 0))
        outputFile = file
        outputURL = url
        totalBytesWritten = 0
        isRecording = true
        isPaused = false

        do {
            try createTapAndAggregateDevice()
            try setupAndStartAudioDevice()
            // The listener is record-only: it timestamps route transitions so
            // the watchdog and mic recovery can defer stall diagnosis until
            // the daemon settles. It never rebuilds — the tap is a global
            // process mix and rides route changes untouched (proven live).
            installDefaultOutputDeviceListener()
            fputs("[system-audio] CoreAudio tap capture started\n", stderr)
        } catch {
            fputs("[system-audio] CoreAudio tap start failed: \(error)\n", stderr)
            cleanupFailedStart()
            throw error
        }
    }

    func stop() -> URL? {
        guard isRecording || outputFile != nil || outputURL != nil else { return nil }
        isRecording = false
        isPaused = false
        captureDeadFlag.store(false, ordering: .releasing)

        removeDefaultOutputDeviceListener()
        // A rebuild retry pending on processingQueue must not fire after
        // teardown (attemptTapRebuild also guards on isRecording, belt and
        // suspenders).
        rebuildRetryWorkItem?.cancel()
        isRebuilding = false
        processingQueue.sync {
            teardownTapAndAudioDevice()
            onPCMSamples = nil
        }

        if let file = outputFile {
            let header = WavWriter.header(dataSize: totalBytesWritten)
            file.seek(toFileOffset: 0)
            file.write(header)
            file.closeFile()
        }
        outputFile = nil

        let bytes = totalBytesWritten
        let url = outputURL
        outputURL = nil
        totalBytesWritten = 0

        fputs("[system-audio] CoreAudio tap stopped, \(bytes) bytes written\n", stderr)
        return url
    }

    func pause() {
        guard isRecording else { return }
        isPaused = true
    }

    func resume() {
        guard isRecording else { return }
        isPaused = false
    }

    // MARK: - Tap + Aggregate Device Setup

    private func createTapAndAggregateDevice() throws {
        // Use the global stereo process mix. This is the closest CoreAudio tap
        // equivalent to ScreenCaptureKit's "system audio" stream: all process
        // output mixed to stereo, excluding Muesli itself. The previous
        // device-stream tap could be valid but zero-filled on some routes.
        let tapDesc = Self.makeGlobalTapDescription(
            excludingProcessID: Self.currentProcessAudioObjectID(),
            name: "Muesli System Audio Tap"
        )

        // Register the tap with the audio system first — this triggers the
        // system permission dialog on first use ("… would like to record audio
        // from other applications").
        var status = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw RecorderError.tapCreationFailed(status)
        }
        fputs("[system-audio] process tap \(tapID) created\n", stderr)

        // Create aggregate device referencing the registered tap by UUID.
        // The tap list must contain dictionaries with UID strings — NOT
        // CATapDescription objects (passing objects crashes CoreAudio).
        let tapUIDString = tapDesc.uuid.uuidString
        // Stable aggregate UID: one identity across all sessions, so an
        // unclean stop can never accumulate fresh HAL settings entries.
        // The daemon enforces UID uniqueness globally, so if a phantom from a
        // crashed session still holds the stable UID (or another Muesli
        // instance is recording), creation fails with 'nope' — in that case we
        // retry once with a single deterministic fallback UID. The fallback is
        // deliberately NOT a fresh UUID: private aggregate devices are
        // invisible to every enumeration/lookup API, so no cleanup sweep can
        // ever find them, and a per-attempt UUID would let repeated crashes in
        // the collision state accumulate permanent HAL settings entries — the
        // exact failure this change exists to remove. Bounding identity count
        // to two caps worst-case permanent leakage at two keys. A refusal on
        // either UID is a phantom signal, so log it loudly.
        var aggUID = "com.muesli.system-audio-tap"
        var aggDesc = Self.makeAggregateDeviceDescription(tapUID: tapUIDString, aggregateUID: aggUID)

        status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateDeviceID)
        if status != noErr || aggregateDeviceID == kAudioObjectUnknown {
            fputs("[system-audio] aggregate creation with stable UID failed (status=\(status)); a phantom or concurrent session may hold it — retrying with fallback UID\n", stderr)
            aggUID = "com.muesli.system-audio-tap-fallback"
            aggDesc = Self.makeAggregateDeviceDescription(tapUID: tapUIDString, aggregateUID: aggUID)
            aggregateDeviceID = kAudioObjectUnknown
            status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateDeviceID)
            if status != noErr || aggregateDeviceID == kAudioObjectUnknown {
                fputs("[system-audio] aggregate creation failed with fallback UID too (status=\(status)); stable+fallback UIDs both held by phantoms or concurrent sessions — restart coreaudiod (sudo killall coreaudiod) or reboot to clear\n", stderr)
            }
        }
        guard status == noErr, aggregateDeviceID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
            throw RecorderError.aggregateDeviceCreationFailed(status)
        }
        fputs("[system-audio] aggregate device \(aggregateDeviceID) created (uid: \(aggUID))\n", stderr)

        sourceFormat = try Self.audioTapStreamFormat(for: tapID)
        sourceSampleRate = sourceFormat.mSampleRate
        sourceChannels = sourceFormat.mChannelsPerFrame
        diagnosticsLock.withLock { state in
            state.sourceSampleRate = sourceSampleRate
            state.sourceChannels = sourceChannels
        }
        fputs("[system-audio] tap format: \(sourceSampleRate)Hz, \(sourceChannels)ch, flags=\(sourceFormat.mFormatFlags), bytesPerFrame=\(sourceFormat.mBytesPerFrame)\n", stderr)
    }

    static func makeGlobalTapDescription(
        excludingProcessID: AudioObjectID?,
        name: String
    ) -> CATapDescription {
        let excludeList = excludingProcessID.map { [$0] } ?? []
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: excludeList)
        tapDesc.name = name
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .unmuted
        return tapDesc
    }

    static func makeAggregateDeviceDescription(tapUID: String, aggregateUID: String) -> NSDictionary {
        [
            kAudioAggregateDeviceNameKey: "Muesli System Audio",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
    }

    private func setupAndStartAudioDevice() throws {
        let format = sourceFormat
        configureResampler(for: format)
        activeCaptureGeneration &+= 1
        let generation = activeCaptureGeneration
        let block: AudioDeviceIOBlock = { [weak self] _, inputData, _, _, _ in
            guard let self, self.isRecording, !self.isPaused else { return }
            self.heartbeatCounter.wrappingIncrement(ordering: .relaxed)
            self.diagnosticsLock.withLock { $0.callbackCount += 1 }

            let buffers = Self.copyAudioBuffers(from: inputData)
            guard !buffers.isEmpty else {
                self.diagnosticsLock.withLock { $0.emptyBufferCount += 1 }
                return
            }
            self.diagnosticsLock.withLock { state in
                state.bufferCount += buffers.count
                state.inputByteCount += buffers.reduce(0) { $0 + $1.data.count }
            }

            self.processingQueue.async { [weak self] in
                guard let self, self.isRecording, !self.isPaused else { return }
                guard self.activeCaptureGeneration == generation else { return }
                self.processAudioBuffers(buffers, format: format)
            }
        }

        var procID: AudioDeviceIOProcID?
        try osCheck(AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregateDeviceID,
            deviceIOQueue,
            block
        ), "create aggregate IOProc")
        guard let procID else {
            throw RecorderError.deviceIOProcCreationFailed
        }

        deviceIOProcID = procID
        deviceIOBlock = block

        do {
            try osCheck(AudioDeviceStart(aggregateDeviceID, procID), "start aggregate device")
        } catch {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            deviceIOProcID = nil
            deviceIOBlock = nil
            throw error
        }
    }

    // MARK: - Audio Processing (processing queue)

    private struct CapturedAudioBuffer {
        let numberChannels: UInt32
        let data: Data
    }

    private static func copyAudioBuffers(from inputData: UnsafePointer<AudioBufferList>) -> [CapturedAudioBuffer] {
        let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        var buffers: [CapturedAudioBuffer] = []
        buffers.reserveCapacity(bufferList.count)

        for buffer in bufferList {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            buffers.append(CapturedAudioBuffer(
                numberChannels: buffer.mNumberChannels,
                data: Data(bytes: data, count: Int(buffer.mDataByteSize))
            ))
        }

        return buffers
    }

    private func processAudioBuffers(_ buffers: [CapturedAudioBuffer], format: AudioStreamBasicDescription) {
        guard isRecording, !isPaused else { return }
        guard let mono = mixToMonoFloat(buffers: buffers, format: format), !mono.isEmpty else { return }
        diagnosticsLock.withLock { $0.preConversion.addFloats(mono) }

        guard let int16Samples = resampleMonoFloatToInt16(mono, sourceSampleRate: format.mSampleRate) else {
            diagnosticsLock.withLock { $0.unsupportedFormatCount += 1 }
            return
        }

        guard !int16Samples.isEmpty else { return }
        let rawData = int16Samples.withUnsafeBufferPointer { buf in
            Data(bytes: buf.baseAddress!, count: buf.count * MemoryLayout<Int16>.size)
        }
        outputFile?.write(rawData)
        totalBytesWritten += rawData.count
        diagnosticsLock.withLock { state in
            state.bytesWritten += rawData.count
            state.postConversion.addInt16(int16Samples)
        }
        onPCMSamples?(int16Samples)
    }

    private func resampleMonoFloatToInt16(_ samples: [Float], sourceSampleRate: Double) -> [Int16]? {
        guard !samples.isEmpty, sourceSampleRate > 0 else { return nil }

        if abs(sourceSampleRate - Self.targetSampleRate) < 1.0 {
            return samples.map { Int16(max(-1.0, min(1.0, $0)) * 32767.0) }
        }

        guard let converter = resampler,
              let inputFormat = resamplerInputFormat,
              let outputFormat = resamplerOutputFormat,
              abs(inputFormat.sampleRate - sourceSampleRate) < 1.0
        else {
            return nil
        }

        let inputFrameCount = AVAudioFrameCount(samples.count)
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: inputFrameCount
        ), let inputChannel = inputBuffer.floatChannelData?[0] else {
            return nil
        }
        inputBuffer.frameLength = inputFrameCount
        inputChannel.update(from: samples, count: samples.count)

        let ratio = Self.targetSampleRate / sourceSampleRate
        let outputFrameCapacity = AVAudioFrameCount(max(1, Int(ceil(Double(samples.count) * ratio)) + 32))
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            return nil
        }

        var didProvideInput = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if didProvideInput {
                status.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            status.pointee = .haveData
            return inputBuffer
        }

        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)
        guard status != .error, conversionError == nil, let outputChannel = outputBuffer.floatChannelData?[0] else {
            if let conversionError {
                fputs("[system-audio] AVAudioConverter failed: \(conversionError)\n", stderr)
            }
            return nil
        }

        let frameLength = Int(outputBuffer.frameLength)
        guard frameLength > 0 else { return nil }
        return (0..<frameLength).map { index in
            Int16(max(-1.0, min(1.0, outputChannel[index])) * 32767.0)
        }
    }

    private func configureResampler(for format: AudioStreamBasicDescription) {
        resampler = nil
        resamplerInputFormat = nil
        resamplerOutputFormat = nil

        guard abs(format.mSampleRate - Self.targetSampleRate) >= 1.0 else { return }
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.mSampleRate,
            channels: 1,
            interleaved: false
        ), let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            diagnosticsLock.withLock { $0.unsupportedFormatCount += 1 }
            fputs("[system-audio] failed to configure AVAudioConverter for \(format.mSampleRate)Hz\n", stderr)
            return
        }

        resampler = converter
        resamplerInputFormat = inputFormat
        resamplerOutputFormat = outputFormat
    }

    private func mixToMonoFloat(
        buffers: [CapturedAudioBuffer],
        format: AudioStreamBasicDescription
    ) -> [Float]? {
        guard format.mFormatID == kAudioFormatLinearPCM else { return nil }

        let flags = format.mFormatFlags
        let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (flags & kAudioFormatFlagIsNonInterleaved) != 0
        let bitsPerChannel = Int(format.mBitsPerChannel)
        let channelCount = max(Int(format.mChannelsPerFrame), 1)

        if isFloat, bitsPerChannel == 32 {
            return mixFloatingPointBuffers(
                buffers,
                channelCount: channelCount,
                isNonInterleaved: isNonInterleaved
            )
        }

        if !isFloat, bitsPerChannel == 16 {
            return mixInt16Buffers(
                buffers,
                channelCount: channelCount,
                isNonInterleaved: isNonInterleaved
            )
        }

        fputs("[system-audio] unsupported tap PCM format flags=\(flags) bits=\(bitsPerChannel)\n", stderr)
        diagnosticsLock.withLock { $0.unsupportedFormatCount += 1 }
        return nil
    }

    private func mixFloatingPointBuffers(
        _ buffers: [CapturedAudioBuffer],
        channelCount: Int,
        isNonInterleaved: Bool
    ) -> [Float]? {
        var mono: [Float] = []
        var channelsMixed = 0

        for buffer in buffers {
            let channels = isNonInterleaved ? max(Int(buffer.numberChannels), 1) : max(Int(buffer.numberChannels), channelCount)
            let samples = buffer.data.withUnsafeBytes { rawBuffer in
                Array(rawBuffer.bindMemory(to: Float.self))
            }
            guard !samples.isEmpty else { continue }

            let frames = samples.count / channels
            if mono.isEmpty {
                mono = [Float](repeating: 0, count: frames)
            }

            let framesToMix = min(mono.count, frames)
            for frame in 0..<framesToMix {
                for channel in 0..<channels {
                    mono[frame] += samples[frame * channels + channel]
                }
            }
            channelsMixed += channels
        }

        guard channelsMixed > 0, !mono.isEmpty else { return nil }
        let scale = 1.0 / Float(channelsMixed)
        for index in mono.indices {
            mono[index] *= scale
        }
        return mono
    }

    private func mixInt16Buffers(
        _ buffers: [CapturedAudioBuffer],
        channelCount: Int,
        isNonInterleaved: Bool
    ) -> [Float]? {
        var mono: [Float] = []
        var channelsMixed = 0

        for buffer in buffers {
            let channels = isNonInterleaved ? max(Int(buffer.numberChannels), 1) : max(Int(buffer.numberChannels), channelCount)
            let samples = buffer.data.withUnsafeBytes { rawBuffer in
                Array(rawBuffer.bindMemory(to: Int16.self))
            }
            guard !samples.isEmpty else { continue }

            let frames = samples.count / channels
            if mono.isEmpty {
                mono = [Float](repeating: 0, count: frames)
            }

            let framesToMix = min(mono.count, frames)
            for frame in 0..<framesToMix {
                for channel in 0..<channels {
                    mono[frame] += Float(samples[frame * channels + channel]) / 32768.0
                }
            }
            channelsMixed += channels
        }

        guard channelsMixed > 0, !mono.isEmpty else { return nil }
        let scale = 1.0 / Float(channelsMixed)
        for index in mono.indices {
            mono[index] *= scale
        }
        return mono
    }

    // MARK: - Permission

    /// Check whether system audio capture permission (`kTCCServiceAudioCapture`)
    /// is granted by attempting to create a device tap on the default output device.
    static func checkSystemAudioPermission() -> Bool {
        guard let selfObjectID = currentProcessAudioObjectID() else { return false }
        let tapDesc = makeGlobalTapDescription(
            excludingProcessID: selfObjectID,
            name: "Muesli Permission Check"
        )

        var testTapID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateProcessTap(tapDesc, &testTapID)
        if status == noErr, testTapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(testTapID)
            return true
        }
        return false
    }

    /// Look up our process's AudioObjectID from the HAL process object list.
    /// `CATapDescription` expects these IDs — not raw PIDs.
    private static func currentProcessAudioObjectID() -> AudioObjectID? {
        let myPID = ProcessInfo.processInfo.processIdentifier
        var propertySize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize
        ) == noErr else { return nil }

        let count = Int(propertySize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return nil }

        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &objects
        ) == noErr else { return nil }

        var pidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for obj in objects {
            var objPID: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(obj, &pidAddr, 0, nil, &pidSize, &objPID) == noErr,
               objPID == myPID {
                return obj
            }
        }
        return nil
    }

    private static func audioTapStreamFormat(for tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else {
            throw RecorderError.tapFormatUnavailable(status)
        }
        return format
    }

    /// Trigger the macOS "System Audio Recording" permission dialog by briefly
    /// starting a CoreAudio tap recording. Per Apple docs, the system prompts
    /// "the first time you start recording from an aggregate device that
    /// contains a tap" — but only if `NSAudioCaptureUsageDescription` is in
    /// Info.plist. Polls for permission for a short period so first-run users
    /// have time to respond before we fall back to Settings.
    @discardableResult
    static func requestSystemAudioAccess(timeout: Duration = .seconds(12)) async -> Bool {
        let recorder = CoreAudioSystemRecorder()
        let pollInterval = Duration.milliseconds(300)
        do {
            try await recorder.start()
        } catch {
            fputs("[system-audio] permission request failed: \(error)\n", stderr)
        }

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if checkSystemAudioPermission() {
                _ = recorder.stop()
                return true
            }
            try? await Task.sleep(for: pollInterval)
        }

        _ = recorder.stop()
        return checkSystemAudioPermission()
    }

    /// Open System Settings to the Screen & System Audio pane where the user
    /// can enable the app under "System Audio Recording Only".
    @MainActor
    static func openSystemAudioSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Stale Device Cleanup

    /// Remove any phantom aggregate devices left behind by a previous crash.
    /// Call once at app launch before starting any recording.
    static func cleanupStaleDevices() {
        var propertySize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize
        ) == noErr else { return }

        let count = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return }

        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &devices
        ) == noErr else { return }

        for deviceID in devices {
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(
                deviceID, &nameAddr, 0, nil, &nameSize, &name
            ) == noErr, let name else { continue }

            if (name.takeRetainedValue() as String) == "Muesli System Audio" {
                fputs("[system-audio] cleaning up stale aggregate device \(deviceID)\n", stderr)
                AudioHardwareDestroyAggregateDevice(deviceID)
            }
        }
    }

    private func installDefaultOutputDeviceListener() {
        guard defaultOutputDeviceListenerBlock == nil else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.processingQueue.async { [weak self] in
                self?.restartTapForDefaultOutputDeviceChange()
            }
        }
        defaultOutputDeviceListenerBlock = block

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            block
        )
    }

    private func removeDefaultOutputDeviceListener() {
        guard let block = defaultOutputDeviceListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            block
        )
        defaultOutputDeviceListenerBlock = nil
    }

    /// All rebuild triggers (route-change listener, watchdog health recovery)
    /// funnel through this single settle-aware scheduler: any pending rebuild
    /// is superseded, and the attempt fires only once the daemon has been
    /// quiet for routeSettleDelay after the last route notification. During
    /// that window the previous tap keeps capturing.
    private func scheduleTapRebuild(reason: String) {
        rebuildRetryWorkItem?.cancel()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let lastRoute = lastRouteChangeAtMs.load(ordering: .relaxed)
        let settleMs = Int64(Self.routeSettleDelay * 1000)
        let deferMs = lastRoute == 0 ? 0 : max(0, settleMs - (nowMs - lastRoute))
        if deferMs > 0 {
            fputs("[system-audio] rebuild deferred \(deferMs)ms for route settle (reason=\(reason))\n", stderr)
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.rebuildRetryCount = 0
            self.attemptTapRebuild(reason: reason)
        }
        rebuildRetryWorkItem = item
        processingQueue.asyncAfter(deadline: .now() + Double(deferMs) / 1000, execute: item)
    }

    /// Called from the default-output listener. The tap is a global process
    /// mix — upstream of any output device — so route changes need NO rebuild
    /// (proven live: the tap rode an AirPods connect/case cycle untouched).
    /// The listener is retained only to timestamp transitions: the watchdog
    /// and the mic recovery coordinator use it to defer stall diagnosis until
    /// the daemon has settled, since the old tap's heartbeat gap during a
    /// transition is expected, not a dead graph.
    func restartTapForDefaultOutputDeviceChange() {
        guard isRecording else { return }
        lastRouteChangeAtMs.store(Int64(Date().timeIntervalSince1970 * 1000), ordering: .relaxed)
        fputs("[system-audio] default output device changed (no rebuild; tap is route-independent)\n", stderr)
    }

    /// Serialized on processingQueue. A failed rebuild retries on a bounded
    /// backoff — the observed failure mode (tapCreationFailed mid-route-churn)
    /// is transient — and only after the budget is exhausted does capture go
    /// terminal, reporting via onCaptureFailure instead of dying silently.
    /// Terminal exhaustion keeps isRecording/onPCMSamples alive (captureDead
    /// marks the state) so a watchdog-driven rebuild can still recover it.
    func attemptTapRebuild(reason: String) {
        guard isRecording else { return }
        isRebuilding = true
        let attempt = rebuildRetryCount + 1
        fputs("[system-audio] rebuilding tap (reason=\(reason), attempt=\(attempt))\n", stderr)
        teardownTapAndAudioDevice()
        guard isRecording else {
            isRebuilding = false
            return
        }
        do {
            if let override = createAndStartForTesting {
                try override()
            } else {
                try createTapAndAggregateDevice()
                try setupAndStartAudioDevice()
            }
            isRebuilding = false
            rebuildRetryCount = 0
            captureDeadFlag.store(false, ordering: .releasing)
            fputs("[system-audio] CoreAudio tap capture restarted (reason=\(reason), attempt=\(attempt))\n", stderr)
        } catch {
            teardownTapAndAudioDevice()
            if let delay = Self.rebuildRetryPolicy.nextDelay(afterFailures: rebuildRetryCount) {
                rebuildRetryCount += 1
                let item = DispatchWorkItem { [weak self] in
                    self?.attemptTapRebuild(reason: reason)
                }
                rebuildRetryWorkItem = item
                processingQueue.asyncAfter(deadline: .now() + delay, execute: item)
                fputs("[system-audio] tap rebuild failed (reason=\(reason), retrying in \(delay)s): \(error)\n", stderr)
            } else {
                isRebuilding = false
                rebuildRetryCount = 0
                // Capture is dead, but stay in a recoverable state: the
                // watchdog's rebuild path (or a later route change) must be
                // able to recreate the graph for the rest of the meeting.
                captureDeadFlag.store(true, ordering: .releasing)
                fputs("[system-audio] tap rebuild exhausted retries; capture dead but recoverable (reason=\(reason)): \(error)\n", stderr)
                onCaptureFailure?(error)
            }
        }
    }

    /// Health-driven rebuild entry point (watchdog: IO heartbeat stalled while
    /// recording). Shares the route-settle gate with the route-change path:
    /// during a transition the old tap's stall is expected, so the rebuild
    /// waits for the churn to settle instead of piling onto the daemon.
    @discardableResult
    func rebuildForHealthRecovery(reason: String) -> Bool {
        guard isRecording, !isPaused else { return false }
        fputs("[system-audio] health-triggered tap rebuild requested: \(reason)\n", stderr)
        processingQueue.async { [weak self] in
            guard let self, self.isRecording else { return }
            self.scheduleTapRebuild(reason: "health_recovery: \(reason)")
        }
        return true
    }

    /// Test-only: drive the recording flag without a real HAL session.
    func testing_setRecording(_ value: Bool) {
        isRecording = value
    }

    // MARK: - Helpers

    enum RecorderError: LocalizedError {
        case fileCreationFailed
        case noDefaultOutputDevice
        case tapCreationFailed(OSStatus)
        case aggregateDeviceCreationFailed(OSStatus)
        case coreAudioSetupFailed(String, OSStatus)
        case deviceIOProcCreationFailed
        case tapFormatUnavailable(OSStatus)

        var errorDescription: String? {
            switch self {
            case .fileCreationFailed:
                return "Could not create output file"
            case .noDefaultOutputDevice:
                return "No default audio output device found"
            case .tapCreationFailed(let s):
                return "Process tap creation failed (status: \(s))"
            case .aggregateDeviceCreationFailed(let s):
                return "Aggregate device creation failed (status: \(s))"
            case .coreAudioSetupFailed(let step, let s):
                return "CoreAudio setup failed at '\(step)' (status: \(s))"
            case .deviceIOProcCreationFailed:
                return "Could not create aggregate device IOProc"
            case .tapFormatUnavailable(let s):
                return "Could not read tap stream format (status: \(s))"
            }
        }
    }

    private func osCheck(_ status: OSStatus, _ label: String) throws {
        guard status == noErr else {
            throw RecorderError.coreAudioSetupFailed(label, status)
        }
    }

    private func teardownTapAndAudioDevice() {
        activeCaptureGeneration &+= 1
        resampler = nil
        resamplerInputFormat = nil
        resamplerOutputFormat = nil

        if let procID = deviceIOProcID, aggregateDeviceID != kAudioObjectUnknown {
            let stopStatus = AudioDeviceStop(aggregateDeviceID, procID)
            let destroyProcStatus = AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            if stopStatus != noErr || destroyProcStatus != noErr {
                fputs("[system-audio] teardown: IO stop/destroy failed on device \(aggregateDeviceID) (stop=\(stopStatus), destroyProc=\(destroyProcStatus))\n", stderr)
            }
        }
        deviceIOProcID = nil
        deviceIOBlock = nil

        if aggregateDeviceID != kAudioObjectUnknown {
            // A failure here previously went silent: we would drop the ID and
            // lose any chance to retry, leaving the object for the daemon to
            // reclaim (or not). Log loudly so field diagnostics can see it.
            let destroyStatus = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if destroyStatus != noErr {
                fputs("[system-audio] teardown: FAILED to destroy aggregate device \(aggregateDeviceID) (status=\(destroyStatus))\n", stderr)
            }
            aggregateDeviceID = kAudioObjectUnknown
        }

        if tapID != kAudioObjectUnknown {
            let destroyTapStatus = AudioHardwareDestroyProcessTap(tapID)
            if destroyTapStatus != noErr {
                fputs("[system-audio] teardown: FAILED to destroy process tap \(tapID) (status=\(destroyTapStatus))\n", stderr)
            }
            tapID = kAudioObjectUnknown
        }
    }

    private func cleanupFailedStart() {
        isRecording = false
        isPaused = false
        onPCMSamples = nil

        removeDefaultOutputDeviceListener()
        teardownTapAndAudioDevice()

        if let file = outputFile {
            file.closeFile()
        }
        outputFile = nil

        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        outputURL = nil
        totalBytesWritten = 0
    }

}
