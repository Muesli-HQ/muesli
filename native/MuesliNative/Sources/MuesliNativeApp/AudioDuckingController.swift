import CoreAudio
import Foundation

protocol AudioDuckingManaging: AnyObject {
    func beginDictationDucking(enabled: Bool)
    func ensureCurrentDefaultDucked()
    func restoreDictationDucking(completion: (() -> Void)?)
}

extension AudioDuckingManaging {
    func restoreDictationDucking() {
        restoreDictationDucking(completion: nil)
    }
}

enum AudioOutputActivityStatus: Equatable, CustomStringConvertible {
    case active
    case inactive
    case unknown

    var description: String {
        switch self {
        case .active: return "active"
        case .inactive: return "inactive"
        case .unknown: return "unknown"
        }
    }
}

protocol AudioDuckingDeviceClient {
    func outputActivityStatus() -> AudioOutputActivityStatus
    func defaultOutputRouteKind() -> AudioOutputRouteKind
    func defaultOutputDeviceID() -> AudioObjectID?
    func isDeviceAvailable(_ deviceID: AudioObjectID) -> Bool
    func nominalSampleRate(for deviceID: AudioObjectID) -> Double?
    func muteElements(for deviceID: AudioObjectID) -> [AudioObjectPropertyElement]
    func isMuted(deviceID: AudioObjectID, element: AudioObjectPropertyElement) -> Bool?
    func setMuted(_ muted: Bool, deviceID: AudioObjectID, element: AudioObjectPropertyElement) -> Bool
    func volumeElements(for deviceID: AudioObjectID) -> [AudioObjectPropertyElement]
    func volume(deviceID: AudioObjectID, element: AudioObjectPropertyElement) -> Float32?
    func setVolume(_ volume: Float32, deviceID: AudioObjectID, element: AudioObjectPropertyElement) -> Bool
}

final class AudioDuckingController: AudioDuckingManaging {
    private struct MuteMutation {
        let element: AudioObjectPropertyElement
        let previousValue: Bool
    }

    private struct VolumeMutation {
        let element: AudioObjectPropertyElement
        let previousValue: Float32
    }

    private struct DeviceSnapshot {
        let deviceID: AudioObjectID
        let sampleRate: Double?
        var muteMutations: [MuteMutation] = []
        var volumeMutations: [VolumeMutation] = []

        var hasMutations: Bool {
            !muteMutations.isEmpty || !volumeMutations.isEmpty
        }
    }

    private let client: AudioDuckingDeviceClient
    private let queue: DispatchQueue
    private let stabilizationTimeout: TimeInterval
    private let stabilizationPollInterval: TimeInterval
    private var duckingEnabledForSession = false
    private var snapshots: [AudioObjectID: DeviceSnapshot] = [:]
    private var restoreGeneration = 0
    private var isRestorePending = false
    private var restoreCompletions: [() -> Void] = []

    init(
        client: AudioDuckingDeviceClient = CoreAudioDuckingDeviceClient(),
        queue: DispatchQueue = DispatchQueue(label: "com.muesli.audio-ducking"),
        stabilizationTimeout: TimeInterval = 0.5,
        stabilizationPollInterval: TimeInterval = 0.05
    ) {
        self.client = client
        self.queue = queue
        self.stabilizationTimeout = stabilizationTimeout
        self.stabilizationPollInterval = stabilizationPollInterval
    }

    func beginDictationDucking(enabled: Bool) {
        queue.async { [self] in
            guard enabled else {
                self.cancelPendingRestoreLocked(preserveCompletions: true)
                self.duckingEnabledForSession = false
                self.restoreLocked(completion: nil)
                return
            }
            self.cancelPendingRestoreLocked(preserveCompletions: false)
            self.duckingEnabledForSession = true
            guard self.shouldDuckCurrentOutput() else { return }
            self.duckCurrentDefaultDevice()
        }
    }

    func ensureCurrentDefaultDucked() {
        queue.async { [self] in
            guard self.duckingEnabledForSession, self.shouldDuckCurrentOutput() else { return }
            self.duckCurrentDefaultDevice()
        }
    }

    func restoreDictationDucking(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            restoreLocked(completion: completion)
        }
    }

    func waitForIdle() {
        queue.sync {}
    }

    private func shouldDuckCurrentOutput() -> Bool {
        guard client.defaultOutputRouteKind() != .headphoneLike else {
            return false
        }
        switch client.outputActivityStatus() {
        case .active, .unknown:
            return true
        case .inactive:
            return false
        }
    }

    private func duckCurrentDefaultDevice() {
        guard let deviceID = client.defaultOutputDeviceID(),
              client.isDeviceAvailable(deviceID),
              snapshots[deviceID] == nil else { return }

        let sampleRate = client.nominalSampleRate(for: deviceID)
        var snapshot = DeviceSnapshot(deviceID: deviceID, sampleRate: sampleRate)

        let muteElements = client.muteElements(for: deviceID)
        for element in muteElements {
            guard let isMuted = client.isMuted(deviceID: deviceID, element: element),
                  !isMuted else { continue }
            if client.setMuted(true, deviceID: deviceID, element: element) {
                snapshot.muteMutations.append(MuteMutation(element: element, previousValue: isMuted))
            }
        }

        if snapshot.muteMutations.isEmpty {
            for element in client.volumeElements(for: deviceID) {
                guard let volume = client.volume(deviceID: deviceID, element: element),
                      volume > 0.0001 else { continue }
                if client.setVolume(0, deviceID: deviceID, element: element) {
                    snapshot.volumeMutations.append(VolumeMutation(element: element, previousValue: volume))
                }
            }
        }

        if snapshot.hasMutations {
            snapshots[deviceID] = snapshot
        }
    }

    private func restoreLocked(completion: (() -> Void)?) {
        if let completion {
            restoreCompletions.append(completion)
        }
        restoreGeneration += 1
        isRestorePending = true
        scheduleRestoreAfterCodecStabilizationLocked(
            generation: restoreGeneration,
            deadline: Date().addingTimeInterval(stabilizationTimeout)
        )
    }

    private func cancelPendingRestoreLocked(preserveCompletions: Bool) {
        guard isRestorePending else { return }
        restoreGeneration += 1
        isRestorePending = false
        if !preserveCompletions {
            restoreCompletions.removeAll()
        }
    }

    private func scheduleRestoreAfterCodecStabilizationLocked(generation: Int, deadline: Date) {
        guard generation == restoreGeneration else { return }
        guard shouldWaitForCodecStabilizationLocked(until: deadline) else {
            applyRestoreLocked(generation: generation)
            return
        }
        queue.asyncAfter(deadline: .now() + stabilizationPollInterval) { [self] in
            scheduleRestoreAfterCodecStabilizationLocked(generation: generation, deadline: deadline)
        }
    }

    private func applyRestoreLocked(generation: Int) {
        guard generation == restoreGeneration else { return }
        let pendingSnapshots = snapshots.values
        snapshots.removeAll()
        duckingEnabledForSession = false
        isRestorePending = false
        let completions = restoreCompletions
        restoreCompletions.removeAll()

        for snapshot in pendingSnapshots {
            guard client.isDeviceAvailable(snapshot.deviceID) else { continue }
            for mutation in snapshot.muteMutations {
                guard client.isMuted(deviceID: snapshot.deviceID, element: mutation.element) == true else {
                    continue
                }
                _ = client.setMuted(mutation.previousValue, deviceID: snapshot.deviceID, element: mutation.element)
            }
            for mutation in snapshot.volumeMutations {
                guard let current = client.volume(deviceID: snapshot.deviceID, element: mutation.element),
                      abs(current) <= 0.0001 else {
                    continue
                }
                _ = client.setVolume(mutation.previousValue, deviceID: snapshot.deviceID, element: mutation.element)
            }
        }
        completions.forEach { $0() }
    }

    private func shouldWaitForCodecStabilizationLocked(until deadline: Date) -> Bool {
        guard stabilizationTimeout > 0, stabilizationPollInterval > 0, Date() < deadline else { return false }
        guard let defaultDeviceID = client.defaultOutputDeviceID(),
              let snapshot = snapshots[defaultDeviceID],
              let previousSampleRate = snapshot.sampleRate,
              let currentSampleRate = client.nominalSampleRate(for: defaultDeviceID),
              abs(currentSampleRate - previousSampleRate) > 0.5 else {
            return false
        }
        return true
    }
}

final class CoreAudioDuckingDeviceClient: AudioDuckingDeviceClient {
    private let currentProcessID = ProcessInfo.processInfo.processIdentifier
    private let inspector: CoreAudioDeviceInspector

    init(inspector: CoreAudioDeviceInspector = CoreAudioDeviceInspector()) {
        self.inspector = inspector
    }

    func outputActivityStatus() -> AudioOutputActivityStatus {
        guard let processIDs = processObjectIDs() else { return .unknown }
        for processObjectID in processIDs {
            guard boolProperty(kAudioProcessPropertyIsRunningOutput, objectID: processObjectID),
                  let pid = pidProperty(objectID: processObjectID),
                  pid > 0,
                  pid != currentProcessID else { continue }
            return .active
        }
        return .inactive
    }

    func defaultOutputRouteKind() -> AudioOutputRouteKind {
        guard let deviceID = defaultOutputDeviceID() else { return .unknown }
        return inspector.outputRouteKind(for: deviceID)
    }

    func defaultOutputDeviceID() -> AudioObjectID? {
        inspector.defaultOutputDeviceID()
    }

    func isDeviceAvailable(_ deviceID: AudioObjectID) -> Bool {
        inspector.isDeviceAvailable(deviceID)
    }

    func nominalSampleRate(for deviceID: AudioObjectID) -> Double? {
        inspector.nominalSampleRate(for: deviceID)
    }

    func muteElements(for deviceID: AudioObjectID) -> [AudioObjectPropertyElement] {
        supportedElements(
            for: kAudioDevicePropertyMute,
            deviceID: deviceID,
            scope: kAudioDevicePropertyScopeOutput
        )
    }

    func isMuted(deviceID: AudioObjectID, element: AudioObjectPropertyElement) -> Bool? {
        var value: UInt32 = 0
        guard getUInt32(
            kAudioDevicePropertyMute,
            objectID: deviceID,
            scope: kAudioDevicePropertyScopeOutput,
            element: element,
            value: &value
        ) else {
            return nil
        }
        return value != 0
    }

    func setMuted(_ muted: Bool, deviceID: AudioObjectID, element: AudioObjectPropertyElement) -> Bool {
        var value: UInt32 = muted ? 1 : 0
        return setUInt32(
            kAudioDevicePropertyMute,
            objectID: deviceID,
            scope: kAudioDevicePropertyScopeOutput,
            element: element,
            value: &value
        )
    }

    func volumeElements(for deviceID: AudioObjectID) -> [AudioObjectPropertyElement] {
        supportedElements(
            for: kAudioDevicePropertyVolumeScalar,
            deviceID: deviceID,
            scope: kAudioDevicePropertyScopeOutput
        )
    }

    func volume(deviceID: AudioObjectID, element: AudioObjectPropertyElement) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        var value = Float32(0)
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value) == noErr else {
            return nil
        }
        return value
    }

    func setVolume(_ volume: Float32, deviceID: AudioObjectID, element: AudioObjectPropertyElement) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        var value = volume
        let dataSize = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, dataSize, &value) == noErr
    }

    private func supportedElements(
        for selector: AudioObjectPropertySelector,
        deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> [AudioObjectPropertyElement] {
        // Dictation ducking only needs the main and common stereo elements.
        // Aggregate/surround channel-specific ducking is intentionally out of scope.
        let candidates = [
            kAudioObjectPropertyElementMain,
            AudioObjectPropertyElement(1),
            AudioObjectPropertyElement(2),
        ]
        return candidates.filter {
            hasProperty(selector, objectID: deviceID, scope: scope, element: $0)
        }
    }

    private func processObjectIDs() -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return nil
        }
        guard dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &ids
        ) == noErr else {
            return nil
        }
        return ids.filter { $0 != AudioObjectID(kAudioObjectUnknown) }
    }

    private func pidProperty(objectID: AudioObjectID) -> pid_t? {
        var pid = pid_t(0)
        guard getPid(kAudioProcessPropertyPID, objectID: objectID, value: &pid) else {
            return nil
        }
        return pid
    }

    private func boolProperty(_ selector: AudioObjectPropertySelector, objectID: AudioObjectID) -> Bool {
        var value: UInt32 = 0
        guard getUInt32(
            selector,
            objectID: objectID,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain,
            value: &value
        ) else {
            return false
        }
        return value != 0
    }

    private func hasProperty(
        _ selector: AudioObjectPropertySelector,
        objectID: AudioObjectID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        return AudioObjectHasProperty(objectID, &address)
    }

    private func getUInt32(
        _ selector: AudioObjectPropertySelector,
        objectID: AudioObjectID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement,
        value: inout UInt32
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value) == noErr
    }

    private func setUInt32(
        _ selector: AudioObjectPropertySelector,
        objectID: AudioObjectID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement,
        value: inout UInt32
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        let dataSize = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(objectID, &address, 0, nil, dataSize, &value) == noErr
    }

    private func getPid(
        _ selector: AudioObjectPropertySelector,
        objectID: AudioObjectID,
        value: inout pid_t
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value) == noErr
    }
}
