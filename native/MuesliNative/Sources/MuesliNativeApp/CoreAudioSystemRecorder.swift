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
    private let recordingFlag = ManagedAtomic(false)
    private let pausedFlag = ManagedAtomic(false)
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
        file.write(WAVHeader.create(dataSize: 0))
        outputFile = file
        outputURL = url
        totalBytesWritten = 0
        isRecording = true
        isPaused = false

        do {
            try createTapAndAggregateDevice()
            try setupAndStartAudioDevice()
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

        removeDefaultOutputDeviceListener()
        processingQueue.sync {
            teardownTapAndAudioDevice()
            onPCMSamples = nil
        }

        if let file = outputFile {
            let header = WAVHeader.create(dataSize: totalBytesWritten)
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
        let aggUID = "com.muesli.system-audio-tap-\(UUID().uuidString)"
        let aggDesc = Self.makeAggregateDeviceDescription(tapUID: tapUIDString, aggregateUID: aggUID)

        status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggregateDeviceID)
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

    static func makeOutputDeviceTapDescription(
        deviceUID: String,
        excludingProcessID: AudioObjectID?,
        name: String
    ) -> CATapDescription {
        let excludeList = excludingProcessID.map { [$0] } ?? []
        // Default output devices expose the render stream we need at index 0 on supported macOS hardware.
        let tapDesc = CATapDescription(excludingProcesses: excludeList, deviceUID: deviceUID, stream: 0)
        tapDesc.name = name
        return tapDesc
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
        let block: AudioDeviceIOBlock = { [weak self] _, inputData, _, _, _ in
            guard let self, self.isRecording, !self.isPaused else { return }
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

        // Resample to 16 kHz and convert to Int16.
        let targetRate = Self.targetSampleRate
        let int16Samples: [Int16]

        if abs(format.mSampleRate - targetRate) < 1.0 {
            int16Samples = mono.map { Int16(max(-1.0, min(1.0, $0)) * 32767.0) }
        } else {
            let ratio = format.mSampleRate / targetRate
            let outputCount = Int(Double(mono.count) / ratio)
            guard outputCount > 0 else { return }
            var resampled = [Int16](repeating: 0, count: outputCount)
            for i in 0..<outputCount {
                let srcPos = Double(i) * ratio
                let idx = Int(srcPos)
                let frac = Float(srcPos - Double(idx))
                let sample: Float
                if idx + 1 < mono.count {
                    sample = mono[idx] * (1.0 - frac) + mono[idx + 1] * frac
                } else if idx < mono.count {
                    sample = mono[idx]
                } else {
                    sample = 0
                }
                resampled[i] = Int16(max(-1.0, min(1.0, sample)) * 32767.0)
            }
            int16Samples = resampled
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

    private func mixToMonoFloat(
        buffers: [CapturedAudioBuffer],
        format: AudioStreamBasicDescription
    ) -> [Float]? {
        guard format.mFormatID == kAudioFormatLinearPCM else { return nil }

        let flags = format.mFormatFlags
        let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
        let bitsPerChannel = Int(format.mBitsPerChannel)

        if isFloat, bitsPerChannel == 32 {
            return mixFloatingPointBuffers(buffers)
        }

        if !isFloat, bitsPerChannel == 16 {
            return mixInt16Buffers(buffers)
        }

        fputs("[system-audio] unsupported tap PCM format flags=\(flags) bits=\(bitsPerChannel)\n", stderr)
        diagnosticsLock.withLock { $0.unsupportedFormatCount += 1 }
        return nil
    }

    private func mixFloatingPointBuffers(_ buffers: [CapturedAudioBuffer]) -> [Float]? {
        var mono: [Float] = []
        var channelsMixed = 0

        for buffer in buffers {
            let channels = max(Int(buffer.numberChannels), 1)
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

    private func mixInt16Buffers(_ buffers: [CapturedAudioBuffer]) -> [Float]? {
        var mono: [Float] = []
        var channelsMixed = 0

        for buffer in buffers {
            let channels = max(Int(buffer.numberChannels), 1)
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

    private struct OutputDeviceTapTarget {
        let uid: String
    }

    private static func defaultOutputDeviceTapTarget() -> OutputDeviceTapTarget? {
        guard let deviceID = defaultOutputDeviceID(),
              let uid = deviceUID(for: deviceID)
        else { return nil }
        return OutputDeviceTapTarget(uid: uid)
    }

    /// Look up the default audio output device ID.
    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else {
            return nil
        }
        return deviceID
    }

    private static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &uid
        ) == noErr, let uid else {
            return nil
        }
        return uid.takeRetainedValue() as String
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

    private func restartTapForDefaultOutputDeviceChange() {
        guard isRecording else { return }

        fputs("[system-audio] default output device changed; rebuilding tap\n", stderr)
        teardownTapAndAudioDevice()
        guard isRecording else { return }

        do {
            try createTapAndAggregateDevice()
            try setupAndStartAudioDevice()
            fputs("[system-audio] CoreAudio tap capture restarted for default output device\n", stderr)
        } catch {
            teardownTapAndAudioDevice()
            isRecording = false
            isPaused = false
            onPCMSamples = nil
            fputs("[system-audio] failed to restart after default output device change: \(error)\n", stderr)
        }
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
        if let procID = deviceIOProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
        }
        deviceIOProcID = nil
        deviceIOBlock = nil

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
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

    // MARK: - WAV Header

    private enum WAVHeader {
        static func create(dataSize: Int) -> Data {
            let sampleRate = Int(CoreAudioSystemRecorder.targetSampleRate)
            let channels = 1
            let byteRate = sampleRate * channels * 16 / 8
            let blockAlign = channels * 16 / 8

            var header = Data()
            header.append(contentsOf: "RIFF".utf8)
            header.append(contentsOf: withUnsafeBytes(of: UInt32(36 + dataSize).littleEndian) { Array($0) })
            header.append(contentsOf: "WAVE".utf8)
            header.append(contentsOf: "fmt ".utf8)
            header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
            header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
            header.append(contentsOf: withUnsafeBytes(of: UInt16(channels).littleEndian) { Array($0) })
            header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
            header.append(contentsOf: withUnsafeBytes(of: UInt32(byteRate).littleEndian) { Array($0) })
            header.append(contentsOf: withUnsafeBytes(of: UInt16(blockAlign).littleEndian) { Array($0) })
            header.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })
            header.append(contentsOf: "data".utf8)
            header.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
            return header
        }
    }
}
