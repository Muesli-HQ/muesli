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
    let hasInputStreams: Bool
    let outputTerminalTypes: Set<UInt32>
    let outputDataSourceKinds: Set<UInt32>
    let nominalSampleRate: Double?

    init(
        name: String?,
        transportType: UInt32?,
        hasOutputStreams: Bool,
        hasInputStreams: Bool,
        outputTerminalTypes: Set<UInt32> = [],
        outputDataSourceKinds: Set<UInt32> = [],
        nominalSampleRate: Double? = nil
    ) {
        self.name = name
        self.transportType = transportType
        self.hasOutputStreams = hasOutputStreams
        self.hasInputStreams = hasInputStreams
        self.outputTerminalTypes = outputTerminalTypes
        self.outputDataSourceKinds = outputDataSourceKinds
        self.nominalSampleRate = nominalSampleRate
    }
}

struct AudioInputDeviceInfo: Equatable, Identifiable {
    let uid: String
    let name: String
    let deviceID: AudioObjectID
    let isBuiltIn: Bool

    var id: String { uid }
}

enum AudioRouteClassifier {
    struct Classification: Equatable {
        let kind: AudioOutputRouteKind
        let isAmbiguousBluetooth: Bool
    }

    static func outputRouteClassification(for device: AudioOutputDeviceDescription) -> Classification {
        Classification(
            kind: outputRouteKind(for: device),
            isAmbiguousBluetooth: isAmbiguousBluetoothWithoutRouteMetadata(device)
        )
    }

    static func outputRouteKind(for device: AudioOutputDeviceDescription) -> AudioOutputRouteKind {
        guard device.hasOutputStreams else { return .unknown }

        let routeKinds = device.outputTerminalTypes.union(device.outputDataSourceKinds)
        if !routeKinds.isDisjoint(with: speakerTerminalTypes) {
            return .speakerLike
        }
        if routeKinds.contains(kAudioStreamTerminalTypeHeadphones) {
            return .headphoneLike
        }

        if device.transportType == kAudioDeviceTransportTypeBluetooth
            || device.transportType == kAudioDeviceTransportTypeBluetoothLE {
            // Avoid brand/product-name heuristics. If CoreAudio does not expose
            // terminal or data-source metadata, a bidirectional Bluetooth device
            // could be either headphones or a speakerphone. Keep that ambiguous
            // instead of skipping ducking for possible external speaker bleed.
            guard !routeKinds.isEmpty else {
                return device.hasInputStreams ? .unknown : .speakerLike
            }
            return .speakerLike
        }

        return .speakerLike
    }

    private static let speakerTerminalTypes: Set<UInt32> = [
        kAudioStreamTerminalTypeSpeaker,
        kAudioStreamTerminalTypeLFESpeaker,
        kAudioStreamTerminalTypeReceiverSpeaker,
    ]

    private static func isAmbiguousBluetoothWithoutRouteMetadata(_ device: AudioOutputDeviceDescription) -> Bool {
        guard device.hasOutputStreams, device.hasInputStreams else { return false }
        guard device.transportType == kAudioDeviceTransportTypeBluetooth
            || device.transportType == kAudioDeviceTransportTypeBluetoothLE else { return false }
        return device.outputTerminalTypes.union(device.outputDataSourceKinds).isEmpty
    }

}

protocol DictationAudioRouting: AnyObject {
    var onPreferredInputDeviceChanged: ((AudioObjectID?) -> Void)? { get set }
    var selectedInputDeviceUID: String? { get set }

    func refreshRouteCache()
    func preferredInputDeviceIDForDictation() -> AudioObjectID?
    func preferredInputDeviceIDForMeeting() -> AudioObjectID?
    func cachedPreferredInputDeviceIDForDictation() -> AudioObjectID?
    func meetingInputRouteSnapshot() -> MeetingMicRouteDiagnosticsSnapshot
    func availableInputDevices() -> [AudioInputDeviceInfo]
    func isDefaultOutputHeadphoneLike() -> Bool
    func currentOutputRouteKindForDebug() -> AudioOutputRouteKind
    func currentRouteDebugDescription() -> String
    func systemDefaultInputIsBuiltInForDictation() -> Bool
    func refreshRouteAfterDictationSession()
}

extension DictationAudioRouting {
    func preferredInputDeviceIDForMeeting() -> AudioObjectID? {
        preferredInputDeviceIDForDictation()
    }

    func meetingInputRouteSnapshot() -> MeetingMicRouteDiagnosticsSnapshot {
        MeetingMicRouteDiagnosticsSnapshot(
            outputRouteKind: currentOutputRouteKindForDebug().description,
            outputIsAmbiguousBluetooth: false,
            selectedInputDeviceUID: selectedInputDeviceUID,
            selectedInputDeviceResolved: true,
            preferredInputDeviceID: preferredInputDeviceIDForMeeting(),
            preferredInputDeviceName: nil,
            defaultInputDeviceID: nil,
            defaultInputDeviceName: nil,
            builtInInputDeviceID: nil,
            systemDefaultInputIsBuiltIn: systemDefaultInputIsBuiltInForDictation()
        )
    }
}

final class DictationAudioRouteController: DictationAudioRouting {
    private struct RouteSnapshot {
        var outputRouteKind: AudioOutputRouteKind = .unknown
        var outputIsAmbiguousBluetooth: Bool = false
        var builtInInputDeviceID: AudioObjectID?
        var defaultInputDeviceID: AudioObjectID?
        var selectedInputDeviceID: AudioObjectID?
        var inputDeviceNamesByID: [AudioObjectID: String] = [:]
        var inputDeviceIDsByUID: [String: AudioObjectID] = [:]

        var systemDefaultInputIsBuiltIn: Bool {
            guard let defaultInputDeviceID, let builtInInputDeviceID else { return false }
            return defaultInputDeviceID == builtInInputDeviceID
        }
    }

    private let inspector: CoreAudioDeviceInspecting
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    private let lock = NSLock()
    private var snapshot = RouteSnapshot()
    private var selectedInputDeviceUIDStorage: String?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var deviceInventoryListener: AudioObjectPropertyListenerBlock?
    private var onPreferredInputDeviceChangedStorage: ((AudioObjectID?) -> Void)?
    var selectedInputDeviceUID: String? {
        get {
            lock.withLock { selectedInputDeviceUIDStorage }
        }
        set {
            let normalized = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let selectedInputDeviceUID = normalized?.isEmpty == false ? normalized : nil
            lock.withLock {
                // Meeting startup only reads this cache, so apply a known
                // selection before its asynchronous CoreAudio verification.
                selectedInputDeviceUIDStorage = selectedInputDeviceUID
                snapshot.selectedInputDeviceID = selectedInputDeviceUID.flatMap {
                    snapshot.inputDeviceIDsByUID[$0]
                }
            }
            refreshRouteCache(notifyEvenIfPreferredUnchanged: true)
        }
    }
    var onPreferredInputDeviceChanged: ((AudioObjectID?) -> Void)? {
        get {
            lock.withLock { onPreferredInputDeviceChangedStorage }
        }
        set {
            lock.withLock { onPreferredInputDeviceChangedStorage = newValue }
        }
    }

    init(
        inspector: CoreAudioDeviceInspecting = CoreAudioDeviceInspector(),
        queue: DispatchQueue = DispatchQueue(label: "com.muesli.dictation-audio-route"),
        observesDefaultOutputChanges: Bool = true
    ) {
        self.inspector = inspector
        self.queue = queue
        self.queue.setSpecific(key: queueKey, value: ())
        let initialOutputClassification = inspector.defaultOutputDeviceID().map {
            inspector.outputRouteClassification(for: $0)
        }
        self.snapshot = RouteSnapshot(
            outputRouteKind: initialOutputClassification?.kind ?? .unknown,
            outputIsAmbiguousBluetooth: initialOutputClassification?.isAmbiguousBluetooth ?? false,
            builtInInputDeviceID: inspector.builtInInputDeviceID(),
            defaultInputDeviceID: inspector.defaultInputDeviceID(),
            selectedInputDeviceID: nil
        )
        if observesDefaultOutputChanges {
            installDefaultOutputListener()
            installDefaultInputListener()
            installDeviceInventoryListener()
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
        if let deviceInventoryListener {
            var address = Self.deviceInventoryAddress()
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                deviceInventoryListener
            )
        }
    }

    func refreshRouteCache() {
        refreshRouteCache(notifyEvenIfPreferredUnchanged: false)
    }

    func refreshRouteCache(notifyEvenIfPreferredUnchanged: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            let next = self.makeRouteSnapshot(refreshingDeviceNames: true)
            let routeChange = self.replaceRouteSnapshot(next)
            let previousPreferredInputDeviceID = routeChange.previousPreferredInputDeviceID
            let preferredInputDeviceID = routeChange.preferredInputDeviceID
            if notifyEvenIfPreferredUnchanged || previousPreferredInputDeviceID != preferredInputDeviceID {
                let handler = self.onPreferredInputDeviceChanged
                handler?(preferredInputDeviceID)
            }
        }
    }

    func preferredInputDeviceIDForDictation() -> AudioObjectID? {
        syncOnRouteQueue {
            let next = makeRouteSnapshot()
            replaceRouteSnapshot(next)
        }
        return Self.preferredInputDeviceID(for: lock.withLock { snapshot })
    }

    func preferredInputDeviceIDForMeeting() -> AudioObjectID? {
        // Meeting startup runs on the main actor. CoreAudio property reads can
        // block indefinitely while the HAL is unhealthy, so never wait for a
        // fresh route read here. Default-device listeners keep this snapshot
        // warm on the dedicated route queue.
        return Self.preferredMeetingInputDeviceID(for: lock.withLock { snapshot })
    }

    func cachedPreferredInputDeviceIDForDictation() -> AudioObjectID? {
        Self.preferredInputDeviceID(for: lock.withLock { snapshot })
    }

    func meetingInputRouteSnapshot() -> MeetingMicRouteDiagnosticsSnapshot {
        // This method is called from meeting startup on the main actor. Reading
        // the lock-protected cache is intentionally the only work performed
        // here: both queue.sync and inspector calls can wedge behind CoreAudio
        // and freeze the prompt, status item, and recording controls.
        let cachedRoute = lock.withLock {
            (snapshot: snapshot, selectedInputDeviceUID: selectedInputDeviceUIDStorage)
        }
        let current = cachedRoute.snapshot
        let preferredInputDeviceID = Self.preferredMeetingInputDeviceID(for: current)
        let selectedInputDeviceUID = cachedRoute.selectedInputDeviceUID
        return MeetingMicRouteDiagnosticsSnapshot(
            outputRouteKind: current.outputRouteKind.description,
            outputIsAmbiguousBluetooth: current.outputIsAmbiguousBluetooth,
            selectedInputDeviceUID: selectedInputDeviceUID,
            selectedInputDeviceResolved: selectedInputDeviceUID == nil || current.selectedInputDeviceID != nil,
            preferredInputDeviceID: preferredInputDeviceID,
            preferredInputDeviceName: preferredInputDeviceID.flatMap { current.inputDeviceNamesByID[$0] },
            defaultInputDeviceID: current.defaultInputDeviceID,
            defaultInputDeviceName: current.defaultInputDeviceID.flatMap { current.inputDeviceNamesByID[$0] },
            builtInInputDeviceID: current.builtInInputDeviceID,
            systemDefaultInputIsBuiltIn: current.systemDefaultInputIsBuiltIn
        )
    }

    func availableInputDevices() -> [AudioInputDeviceInfo] {
        inspector.availableInputDevices()
    }

    func isDefaultOutputHeadphoneLike() -> Bool {
        // Unknown outputs are treated as non-speaker for lifecycle sounds so we
        // avoid playing cues into headphones during CoreAudio route transitions.
        // Dictation ducking is stricter: when enabled, it ducks any route that
        // is not confirmed headphone-like to avoid speaker bleed.
        lock.withLock { snapshot.outputRouteKind != .speakerLike }
    }

    func currentOutputRouteKindForDebug() -> AudioOutputRouteKind {
        lock.withLock { snapshot.outputRouteKind }
    }

    func currentRouteDebugDescription() -> String {
        let current = lock.withLock { snapshot }
        let preferredInput = Self.preferredInputDeviceID(for: current)
            .map(String.init) ?? "default"
        return "output=\(current.outputRouteKind.description) preferredInput=\(preferredInput) defaultInputBuiltIn=\(current.systemDefaultInputIsBuiltIn)"
    }

    func systemDefaultInputIsBuiltInForDictation() -> Bool {
        lock.withLock { snapshot.systemDefaultInputIsBuiltIn }
    }

    func refreshRouteAfterDictationSession() {
        syncOnRouteQueue {
            let current = makeRouteSnapshot()
            replaceRouteSnapshot(current)
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
        if let selectedInputDeviceID = snapshot.selectedInputDeviceID {
            return selectedInputDeviceID
        }
        switch snapshot.outputRouteKind {
        case .headphoneLike:
            return snapshot.builtInInputDeviceID
        case .speakerLike:
            return nil
        case .unknown:
            return snapshot.outputIsAmbiguousBluetooth ? snapshot.builtInInputDeviceID : nil
        }
    }

    private static func preferredMeetingInputDeviceID(for snapshot: RouteSnapshot) -> AudioObjectID? {
        let desiredInputDeviceID = snapshot.selectedInputDeviceID ?? snapshot.builtInInputDeviceID

        // A nil meeting preference means "use the system-default recorder".
        // Avoid forcing the same physical device through the app-scoped
        // AudioQueue path: opening that second explicit input context can
        // disrupt a meeting client's already-running microphone graph.
        guard desiredInputDeviceID != snapshot.defaultInputDeviceID else {
            return nil
        }
        return desiredInputDeviceID
    }

    private func makeRouteSnapshot(refreshingDeviceNames: Bool = false) -> RouteSnapshot {
        let outputClassification = currentOutputRouteClassification()
        let cachedRoute = lock.withLock {
            (
                selectedInputDeviceUID: selectedInputDeviceUIDStorage,
                inputDeviceNamesByID: snapshot.inputDeviceNamesByID,
                inputDeviceIDsByUID: snapshot.inputDeviceIDsByUID
            )
        }
        let inputDevices = refreshingDeviceNames ? inspector.availableInputDevices() : nil
        let inputDeviceNamesByID = inputDevices.map { devices in
            Dictionary(
                devices.map { ($0.deviceID, $0.name) },
                uniquingKeysWith: { first, _ in first }
            )
        } ?? cachedRoute.inputDeviceNamesByID
        var inputDeviceIDsByUID = inputDevices.map { devices in
            Dictionary(
                devices.map { ($0.uid, $0.deviceID) },
                uniquingKeysWith: { first, _ in first }
            )
        } ?? cachedRoute.inputDeviceIDsByUID
        let selectedInputDeviceID = cachedRoute.selectedInputDeviceUID.flatMap { uid -> AudioObjectID? in
            if inputDevices != nil {
                return inputDeviceIDsByUID[uid]
            }
            let deviceID = inspector.inputDeviceID(matchingUID: uid)
            if let deviceID {
                inputDeviceIDsByUID[uid] = deviceID
            } else {
                inputDeviceIDsByUID.removeValue(forKey: uid)
            }
            return deviceID
        }
        return RouteSnapshot(
            outputRouteKind: outputClassification.kind,
            outputIsAmbiguousBluetooth: outputClassification.isAmbiguousBluetooth,
            builtInInputDeviceID: inspector.builtInInputDeviceID(),
            defaultInputDeviceID: inspector.defaultInputDeviceID(),
            selectedInputDeviceID: selectedInputDeviceID,
            inputDeviceNamesByID: inputDeviceNamesByID,
            inputDeviceIDsByUID: inputDeviceIDsByUID
        )
    }

    @discardableResult
    private func replaceRouteSnapshot(
        _ next: RouteSnapshot
    ) -> (previousPreferredInputDeviceID: AudioObjectID?, preferredInputDeviceID: AudioObjectID?) {
        lock.withLock {
            let previousPreferredInputDeviceID = Self.preferredInputDeviceID(for: snapshot)
            var reconciled = next
            // CoreAudio inspection can outlive a selection change. Resolve the
            // latest UID against the candidate's freshly populated inventory.
            reconciled.selectedInputDeviceID = selectedInputDeviceUIDStorage.flatMap {
                reconciled.inputDeviceIDsByUID[$0]
            }
            snapshot = reconciled
            return (
                previousPreferredInputDeviceID,
                Self.preferredInputDeviceID(for: reconciled)
            )
        }
    }

    private func currentOutputRouteClassification() -> AudioRouteClassifier.Classification {
        guard let outputDeviceID = inspector.defaultOutputDeviceID() else {
            return AudioRouteClassifier.Classification(kind: .unknown, isAmbiguousBluetooth: false)
        }
        return inspector.outputRouteClassification(for: outputDeviceID)
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

    private func installDeviceInventoryListener() {
        var address = Self.deviceInventoryAddress()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // A selected non-default microphone can disappear or return without
            // changing either system-default device. Refresh its UID resolution
            // so meeting startup never consumes a stale AudioObjectID.
            self?.refreshRouteCache(notifyEvenIfPreferredUnchanged: true)
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listener
        )
        if status == noErr {
            deviceInventoryListener = listener
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

    private static func deviceInventoryAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

protocol CoreAudioDeviceInspecting {
    func defaultOutputDeviceID() -> AudioObjectID?
    func defaultInputDeviceID() -> AudioObjectID?
    func setDefaultInputDeviceID(_ deviceID: AudioObjectID) -> Bool
    func availableInputDevices() -> [AudioInputDeviceInfo]
    func inputDeviceID(matchingUID uid: String) -> AudioObjectID?
    func isDeviceAvailable(_ deviceID: AudioObjectID) -> Bool
    func nominalSampleRate(for deviceID: AudioObjectID) -> Double?
    func outputRouteClassification(for deviceID: AudioObjectID) -> AudioRouteClassifier.Classification
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

    func availableInputDevices() -> [AudioInputDeviceInfo] {
        allDeviceIDs()
            .filter { hasStreams(deviceID: $0, scope: kAudioDevicePropertyScopeInput) }
            .compactMap { deviceID in
                guard let uid = deviceUID(for: deviceID) else { return nil }
                guard !Self.isSystemDefaultAggregateDeviceUID(uid) else { return nil }
                let name = deviceName(for: deviceID) ?? "Microphone \(deviceID)"
                return AudioInputDeviceInfo(
                    uid: uid,
                    name: name,
                    deviceID: deviceID,
                    isBuiltIn: transportType(for: deviceID) == kAudioDeviceTransportTypeBuiltIn
                )
            }
            .sorted { lhs, rhs in
                inputDeviceSortKey(lhs.deviceID) < inputDeviceSortKey(rhs.deviceID)
            }
    }

    func inputDeviceID(matchingUID uid: String) -> AudioObjectID? {
        guard !Self.isSystemDefaultAggregateDeviceUID(uid) else { return nil }
        return allDeviceIDs().first { deviceID in
            hasStreams(deviceID: deviceID, scope: kAudioDevicePropertyScopeInput)
                && deviceUID(for: deviceID) == uid
        }
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

    func outputRouteClassification(for deviceID: AudioObjectID) -> AudioRouteClassifier.Classification {
        AudioRouteClassifier.outputRouteClassification(for: outputDeviceDescription(for: deviceID))
    }

    func outputRouteKind(for deviceID: AudioObjectID) -> AudioOutputRouteKind {
        outputRouteClassification(for: deviceID).kind
    }

    private func outputDeviceDescription(for deviceID: AudioObjectID) -> AudioOutputDeviceDescription {
        AudioOutputDeviceDescription(
            name: deviceName(for: deviceID),
            transportType: transportType(for: deviceID),
            hasOutputStreams: hasStreams(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput),
            hasInputStreams: hasStreams(deviceID: deviceID, scope: kAudioDevicePropertyScopeInput),
            outputTerminalTypes: outputTerminalTypes(for: deviceID),
            outputDataSourceKinds: outputDataSourceKinds(for: deviceID),
            nominalSampleRate: nominalSampleRate(for: deviceID)
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

    private func deviceUID(for deviceID: AudioObjectID) -> String? {
        stringProperty(kAudioDevicePropertyDeviceUID, objectID: deviceID)
    }

    private static func isSystemDefaultAggregateDeviceUID(_ uid: String) -> Bool {
        uid.hasPrefix("CADefaultDeviceAggregate")
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

    private func stringProperty(_ selector: AudioObjectPropertySelector, objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value) == noErr,
              let value else {
            return nil
        }
        return value.takeRetainedValue() as String
    }

    private func hasStreams(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        !streamIDs(deviceID: deviceID, scope: scope).isEmpty
    }

    private func outputTerminalTypes(for deviceID: AudioObjectID) -> Set<UInt32> {
        Set(
            streamIDs(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)
                .compactMap { streamID in terminalType(for: streamID) }
        )
    }

    private func outputDataSourceKinds(for deviceID: AudioObjectID) -> Set<UInt32> {
        Set(
            currentDataSourceIDs(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)
                .compactMap { sourceID in dataSourceKind(for: sourceID, deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput) }
        )
    }

    private func streamIDs(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize >= MemoryLayout<AudioObjectID>.size else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &ids) == noErr else {
            return []
        }
        return ids.filter { $0 != AudioObjectID(kAudioObjectUnknown) }
    }

    private func terminalType(for streamID: AudioObjectID) -> UInt32? {
        var terminalType = UInt32(0)
        guard getUInt32(
            kAudioStreamPropertyTerminalType,
            objectID: streamID,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain,
            value: &terminalType
        ) else {
            return nil
        }
        return terminalType
    }

    private func currentDataSourceIDs(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> [UInt32] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize >= MemoryLayout<UInt32>.size else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<UInt32>.size
        var ids = [UInt32](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &ids) == noErr else {
            return []
        }
        return ids
    }

    private func dataSourceKind(
        for sourceID: UInt32,
        deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSourceKindForID,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var source = sourceID
        var kind = UInt32(0)
        let sourceSize = UInt32(MemoryLayout<UInt32>.size)
        let kindSize = UInt32(MemoryLayout<UInt32>.size)
        var result: UInt32?
        withUnsafeMutablePointer(to: &source) { sourcePointer in
            withUnsafeMutablePointer(to: &kind) { kindPointer in
                var translation = AudioValueTranslation(
                    mInputData: sourcePointer,
                    mInputDataSize: sourceSize,
                    mOutputData: kindPointer,
                    mOutputDataSize: kindSize
                )
                var dataSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
                guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &translation) == noErr else {
                    return
                }
                result = kindPointer.pointee
            }
        }
        return result
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
