import AudioToolbox
@preconcurrency import AVFoundation
import CoreAudio
import Foundation

enum AudioOutputRouteKind: Equatable, CustomStringConvertible {
    case speakerLike
    case headphoneLike
    case unknown

    var description: String {
        switch self {
        case .speakerLike: return "speaker-like"
        case .headphoneLike: return "headphone-like"
        case .unknown: return "unknown"
        }
    }
}

struct AudioOutputDeviceDescription: Equatable {
    let name: String?
    let transportType: UInt32?
    let hasOutputStreams: Bool
}

enum AudioRouteClassifier {
    static func outputRouteKind(for device: AudioOutputDeviceDescription) -> AudioOutputRouteKind {
        guard device.hasOutputStreams else { return .unknown }

        let normalizedName = (device.name ?? "").lowercased()
        if containsAny(normalizedName, keywords: headphoneKeywords) {
            return .headphoneLike
        }

        if device.transportType == kAudioDeviceTransportTypeBluetooth
            || device.transportType == kAudioDeviceTransportTypeBluetoothLE {
            return containsAny(normalizedName, keywords: bluetoothSpeakerKeywords)
                ? .speakerLike
                : .headphoneLike
        }

        return .speakerLike
    }

    private static let headphoneKeywords = [
        "airpods",
        "earpods",
        "earbuds",
        "headphone",
        "headphones",
        "headset",
        "buds",
        "beats",
        "wh-",
        "wf-",
        "xm3",
        "xm4",
        "xm5",
        "bose qc",
        "quietcomfort",
        "jabra",
        "elite",
        "galaxy buds",
        "pixel buds",
    ]

    private static let bluetoothSpeakerKeywords = [
        "speaker",
        "soundbar",
        "sonos",
        "homepod",
        "jbl",
        "flip",
        "charge",
        "boom",
        "echo",
        "nest audio",
    ]

    private static func containsAny(_ value: String, keywords: [String]) -> Bool {
        keywords.contains { value.contains($0) }
    }
}

protocol DictationAudioRouting: AnyObject {
    var onPreferredInputDeviceChanged: ((AudioObjectID?) -> Void)? { get set }

    func refreshRouteCache()
    func preferredInputDeviceIDForDictation() -> AudioObjectID?
    func cachedPreferredInputDeviceIDForDictation() -> AudioObjectID?
    func isDefaultOutputHeadphoneLike() -> Bool
    func currentOutputRouteKindForDebug() -> AudioOutputRouteKind
    func currentRouteDebugDescription() -> String
    func refreshRouteAfterDictationSession()
}

final class DictationAudioRouteController: DictationAudioRouting {
    private struct RouteSnapshot {
        var outputRouteKind: AudioOutputRouteKind = .unknown
        var builtInInputDeviceID: AudioObjectID?
    }

    private let inspector: CoreAudioDeviceInspecting
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    private let lock = NSLock()
    private var snapshot = RouteSnapshot()
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    var onPreferredInputDeviceChanged: ((AudioObjectID?) -> Void)?

    init(
        inspector: CoreAudioDeviceInspecting = CoreAudioDeviceInspector(),
        queue: DispatchQueue = DispatchQueue(label: "com.muesli.dictation-audio-route"),
        observesDefaultOutputChanges: Bool = true
    ) {
        self.inspector = inspector
        self.queue = queue
        self.queue.setSpecific(key: queueKey, value: ())
        self.snapshot = RouteSnapshot(
            outputRouteKind: inspector.defaultOutputDeviceID().map {
                inspector.outputRouteKind(for: $0)
            } ?? .unknown,
            builtInInputDeviceID: inspector.builtInInputDeviceID()
        )
        if observesDefaultOutputChanges {
            installDefaultOutputListener()
            installDefaultInputListener()
        }
        refreshRouteCache()
    }

    deinit {
        if let defaultOutputListener {
            var address = Self.defaultOutputDeviceAddress()
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                defaultOutputListener
            )
        }
        if let defaultInputListener {
            var address = Self.defaultInputDeviceAddress()
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                defaultInputListener
            )
        }
    }

    func refreshRouteCache() {
        refreshRouteCache(notifyEvenIfPreferredUnchanged: false)
    }

    private func refreshRouteCache(notifyEvenIfPreferredUnchanged: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            let next = self.makeRouteSnapshot()
            let previousPreferredInputDeviceID = self.lock.withLock { () -> AudioObjectID? in
                let previous = self.snapshot
                self.snapshot = next
                return Self.preferredInputDeviceID(for: previous)
            }
            let preferredInputDeviceID = Self.preferredInputDeviceID(for: next)
            if notifyEvenIfPreferredUnchanged || previousPreferredInputDeviceID != preferredInputDeviceID {
                self.onPreferredInputDeviceChanged?(preferredInputDeviceID)
            }
        }
    }

    func preferredInputDeviceIDForDictation() -> AudioObjectID? {
        syncOnRouteQueue {
            let next = makeRouteSnapshot()
            lock.withLock {
                snapshot = next
            }
        }
        return Self.preferredInputDeviceID(for: lock.withLock { snapshot })
    }

    func cachedPreferredInputDeviceIDForDictation() -> AudioObjectID? {
        Self.preferredInputDeviceID(for: lock.withLock { snapshot })
    }

    func isDefaultOutputHeadphoneLike() -> Bool {
        // Unknown outputs are treated as non-speaker for lifecycle sounds so we
        // avoid playing cues into headphones during CoreAudio route transitions.
        // Ducking uses RouteSnapshot.shouldDuck and still fails open for unknown.
        lock.withLock { snapshot.outputRouteKind != .speakerLike }
    }

    func currentOutputRouteKindForDebug() -> AudioOutputRouteKind {
        lock.withLock { snapshot.outputRouteKind }
    }

    func currentRouteDebugDescription() -> String {
        let current = lock.withLock { snapshot }
        let preferredInput = Self.preferredInputDeviceID(for: current)
            .map(String.init) ?? "default"
        return "output=\(current.outputRouteKind.description) preferredInput=\(preferredInput)"
    }

    func refreshRouteAfterDictationSession() {
        syncOnRouteQueue {
            let current = makeRouteSnapshot()
            lock.withLock {
                snapshot = current
            }
        }
    }

    private func syncOnRouteQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    private static func preferredInputDeviceID(for snapshot: RouteSnapshot) -> AudioObjectID? {
        guard snapshot.outputRouteKind == .headphoneLike else { return nil }
        return snapshot.builtInInputDeviceID
    }

    private func makeRouteSnapshot() -> RouteSnapshot {
        RouteSnapshot(
            outputRouteKind: currentOutputRouteKind(),
            builtInInputDeviceID: inspector.builtInInputDeviceID()
        )
    }

    private func currentOutputRouteKind() -> AudioOutputRouteKind {
        guard let outputDeviceID = inspector.defaultOutputDeviceID() else { return .unknown }
        return inspector.outputRouteKind(for: outputDeviceID)
    }

    private func installDefaultOutputListener() {
        var address = Self.defaultOutputDeviceAddress()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshRouteCache()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listener
        )
        if status == noErr {
            defaultOutputListener = listener
        }
    }

    private func installDefaultInputListener() {
        var address = Self.defaultInputDeviceAddress()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshRouteCache(notifyEvenIfPreferredUnchanged: true)
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listener
        )
        if status == noErr {
            defaultInputListener = listener
        }
    }

    private static func defaultOutputDeviceAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func defaultInputDeviceAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

protocol CoreAudioDeviceInspecting {
    func defaultOutputDeviceID() -> AudioObjectID?
    func defaultInputDeviceID() -> AudioObjectID?
    func setDefaultInputDeviceID(_ deviceID: AudioObjectID) -> Bool
    func isDeviceAvailable(_ deviceID: AudioObjectID) -> Bool
    func nominalSampleRate(for deviceID: AudioObjectID) -> Double?
    func outputRouteKind(for deviceID: AudioObjectID) -> AudioOutputRouteKind
    func builtInInputDeviceID() -> AudioObjectID?
}

final class CoreAudioDeviceInspector: CoreAudioDeviceInspecting {
    func defaultOutputDeviceID() -> AudioObjectID? {
        defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    func defaultInputDeviceID() -> AudioObjectID? {
        defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    func setDefaultInputDeviceID(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableDeviceID = deviceID
        let dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            dataSize,
            &mutableDeviceID
        ) == noErr
    }

    func isDeviceAvailable(_ deviceID: AudioObjectID) -> Bool {
        deviceID != AudioObjectID(kAudioObjectUnknown)
            && hasProperty(
                kAudioObjectPropertyName,
                objectID: deviceID,
                scope: kAudioObjectPropertyScopeGlobal,
                element: kAudioObjectPropertyElementMain
            )
    }

    func nominalSampleRate(for deviceID: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = Float64(0)
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &sampleRate) == noErr else {
            return nil
        }
        return sampleRate
    }

    func outputRouteKind(for deviceID: AudioObjectID) -> AudioOutputRouteKind {
        AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: deviceName(for: deviceID),
                transportType: transportType(for: deviceID),
                hasOutputStreams: hasStreams(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)
            )
        )
    }

    func builtInInputDeviceID() -> AudioObjectID? {
        let builtInInputs = allDeviceIDs().filter {
            transportType(for: $0) == kAudioDeviceTransportTypeBuiltIn
                && hasStreams(deviceID: $0, scope: kAudioDevicePropertyScopeInput)
        }
        return builtInInputs.sorted { inputDeviceSortKey($0) < inputDeviceSortKey($1) }.first
    }

    private func inputDeviceSortKey(_ deviceID: AudioObjectID) -> String {
        let name = (deviceName(for: deviceID) ?? "").lowercased()
        if name.contains("microphone") { return "0-\(name)" }
        if name.contains("macbook") { return "1-\(name)" }
        if name.contains("built-in") { return "2-\(name)" }
        return "9-\(name)"
    }

    private func allDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
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
        ) == noErr, dataSize > 0 else {
            return []
        }

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
            return []
        }
        return ids.filter { $0 != AudioObjectID(kAudioObjectUnknown) }
    }

    private func defaultDeviceID(selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        ) == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }
        return deviceID
    }

    private func deviceName(for deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &name) == noErr,
              let name else {
            return nil
        }
        return name.takeRetainedValue() as String
    }

    private func transportType(for deviceID: AudioObjectID) -> UInt32? {
        var transportType = UInt32(0)
        guard getUInt32(
            kAudioDevicePropertyTransportType,
            objectID: deviceID,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain,
            value: &transportType
        ) else {
            return nil
        }
        return transportType
    }

    private func hasStreams(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr
            && dataSize >= MemoryLayout<AudioObjectID>.size
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
}

enum AudioInputDeviceSelection {
    static func applyPreferredInputDeviceID(
        _ preferredInputDeviceID: AudioObjectID?,
        to engine: AVAudioEngine,
        logPrefix: String
    ) {
        guard var deviceID = preferredInputDeviceID else {
            return
        }
        guard let audioUnit = engine.inputNode.audioUnit else {
            fputs("[\(logPrefix)] no audio unit available for preferred input routing\n", stderr)
            return
        }

        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        if status != noErr {
            fputs("[\(logPrefix)] failed to set preferred input device \(deviceID): \(status)\n", stderr)
        }
    }
}
