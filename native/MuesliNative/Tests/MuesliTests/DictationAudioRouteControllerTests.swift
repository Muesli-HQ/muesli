import CoreAudio
import Testing
@testable import MuesliNativeApp

@Suite("DictationAudioRouteController")
struct DictationAudioRouteControllerTests {
    @Test("dictation prefers built-in mic for headphone output")
    func dictationPrefersBuiltInMicForHeadphoneOutput() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .headphoneLike,
            builtInInputDeviceID: 82
        )
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: DispatchQueue(label: "test.dictation-audio-route.headphone-like"),
            observesDefaultOutputChanges: false
        )

        #expect(controller.preferredInputDeviceIDForDictation() == 82)
        #expect(controller.cachedPreferredInputDeviceIDForDictation() == 82)
    }

    @Test("meeting reuses route-aware preferred input policy")
    func meetingReusesRouteAwarePreferredInputPolicy() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .headphoneLike,
            builtInInputDeviceID: 82
        )
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: DispatchQueue(label: "test.dictation-audio-route.meeting-headphone-like"),
            observesDefaultOutputChanges: false
        )

        #expect(controller.preferredInputDeviceIDForMeeting() == 82)
        #expect(controller.meetingInputRouteSnapshot().preferredInputDeviceID == 82)
        #expect(controller.meetingInputRouteSnapshot().outputRouteKind == "headphone-like")
    }

    @Test("meeting uses system default recorder when built-in mic is already default")
    func meetingUsesSystemDefaultRecorderForDefaultBuiltInMic() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .speakerLike,
            defaultInputDeviceID: 82,
            builtInInputDeviceID: 82
        )
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: DispatchQueue(label: "test.dictation-audio-route.meeting-default-built-in"),
            observesDefaultOutputChanges: false
        )

        #expect(controller.preferredInputDeviceIDForMeeting() == nil)
        #expect(controller.meetingInputRouteSnapshot().preferredInputDeviceID == nil)
        #expect(controller.meetingInputRouteSnapshot().defaultInputDeviceID == 82)
    }

    @Test("meeting route snapshot never performs synchronous CoreAudio inspection")
    func meetingRouteSnapshotUsesCacheOnly() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .headphoneLike,
            defaultInputDeviceID: 82,
            builtInInputDeviceID: 82
        )
        let routeQueue = DispatchQueue(label: "test.dictation-audio-route.meeting-cache-only")
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: routeQueue,
            observesDefaultOutputChanges: false
        )
        // Drain the initialization refresh before measuring the synchronous call.
        routeQueue.sync {}
        let inspectionCountBeforeSnapshot = inspector.inspectionCallCount

        let snapshot = controller.meetingInputRouteSnapshot()

        #expect(snapshot.preferredInputDeviceID == nil)
        #expect(snapshot.defaultInputDeviceID == 82)
        #expect(inspector.inspectionCallCount == inspectionCountBeforeSnapshot)
    }

    @Test("dictation preserves default input for speaker output")
    func dictationPreservesDefaultInputForSpeakerOutput() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .speakerLike,
            defaultInputDeviceID: 82,
            builtInInputDeviceID: 82
        )
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: DispatchQueue(label: "test.dictation-audio-route.speaker-like"),
            observesDefaultOutputChanges: false
        )

        #expect(controller.preferredInputDeviceIDForDictation() == nil)
        #expect(controller.cachedPreferredInputDeviceIDForDictation() == nil)
        #expect(controller.systemDefaultInputIsBuiltInForDictation())
        #expect(controller.preferredInputDeviceIDForMeeting() == nil)
        #expect(controller.meetingInputRouteSnapshot().preferredInputDeviceID == nil)
    }

    @Test("speaker output with non-built-in default input is not warmup-safe")
    func speakerOutputWithNonBuiltInDefaultInputIsNotWarmupSafe() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .speakerLike,
            defaultInputDeviceID: 91,
            builtInInputDeviceID: 82
        )
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: DispatchQueue(label: "test.dictation-audio-route.speaker-like-risky-input"),
            observesDefaultOutputChanges: false
        )

        #expect(controller.preferredInputDeviceIDForDictation() == nil)
        #expect(!controller.systemDefaultInputIsBuiltInForDictation())
    }

    @Test("dictation prefers built-in mic for ambiguous Bluetooth unknown output")
    func dictationPrefersBuiltInMicForAmbiguousBluetoothUnknownOutput() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .unknown,
            outputIsAmbiguousBluetooth: true,
            builtInInputDeviceID: 82
        )
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: DispatchQueue(label: "test.dictation-audio-route.unknown"),
            observesDefaultOutputChanges: false
        )

        #expect(controller.preferredInputDeviceIDForDictation() == 82)
        #expect(controller.cachedPreferredInputDeviceIDForDictation() == 82)
    }

    @Test("dictation preserves default input for non-Bluetooth unknown output")
    func dictationPreservesDefaultInputForNonBluetoothUnknownOutput() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .unknown,
            outputIsAmbiguousBluetooth: false,
            builtInInputDeviceID: 82
        )
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: DispatchQueue(label: "test.dictation-audio-route.unknown-non-bluetooth"),
            observesDefaultOutputChanges: false
        )

        #expect(controller.preferredInputDeviceIDForDictation() == nil)
        #expect(controller.cachedPreferredInputDeviceIDForDictation() == nil)
    }

    @Test("dictation falls back to default input when built-in mic is unavailable")
    func dictationFallsBackWhenBuiltInMicUnavailable() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .headphoneLike,
            builtInInputDeviceID: nil
        )
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: DispatchQueue(label: "test.dictation-audio-route.no-built-in"),
            observesDefaultOutputChanges: false
        )

        #expect(controller.preferredInputDeviceIDForDictation() == nil)
        #expect(controller.cachedPreferredInputDeviceIDForDictation() == nil)
    }

    @Test("user selected microphone overrides automatic route policy")
    func userSelectedMicrophoneOverridesAutomaticRoutePolicy() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .headphoneLike,
            builtInInputDeviceID: 82,
            inputDevices: [
                AudioInputDeviceInfo(uid: "external-mic", name: "External Mic", deviceID: 91, isBuiltIn: false),
                AudioInputDeviceInfo(uid: "built-in-mic", name: "MacBook Microphone", deviceID: 82, isBuiltIn: true),
            ]
        )
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: DispatchQueue(label: "test.dictation-audio-route.selected-input"),
            observesDefaultOutputChanges: false
        )
        controller.selectedInputDeviceUID = "external-mic"

        #expect(controller.preferredInputDeviceIDForDictation() == 91)
        #expect(controller.cachedPreferredInputDeviceIDForDictation() == 91)
        #expect(controller.preferredInputDeviceIDForMeeting() == 91)
    }

    @Test("user selected default microphone uses system default recorder")
    func userSelectedDefaultMicrophoneUsesSystemDefaultRecorder() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .headphoneLike,
            defaultInputDeviceID: 91,
            builtInInputDeviceID: 82,
            inputDevices: [
                AudioInputDeviceInfo(uid: "external-mic", name: "External Mic", deviceID: 91, isBuiltIn: false),
                AudioInputDeviceInfo(uid: "built-in-mic", name: "MacBook Microphone", deviceID: 82, isBuiltIn: true),
            ]
        )
        let routeQueue = DispatchQueue(label: "test.dictation-audio-route.selected-default-input")
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: routeQueue,
            observesDefaultOutputChanges: false
        )
        controller.selectedInputDeviceUID = "external-mic"
        routeQueue.sync {}

        #expect(controller.preferredInputDeviceIDForMeeting() == nil)
        let snapshot = controller.meetingInputRouteSnapshot()
        #expect(snapshot.preferredInputDeviceID == nil)
        #expect(snapshot.selectedInputDeviceResolved)
        #expect(snapshot.defaultInputDeviceID == 91)
    }

    @Test("meeting immediately observes a cached microphone selection")
    func meetingImmediatelyObservesCachedMicrophoneSelection() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .speakerLike,
            defaultInputDeviceID: 82,
            builtInInputDeviceID: 82,
            inputDevices: [
                AudioInputDeviceInfo(uid: "external-mic", name: "External Mic", deviceID: 91, isBuiltIn: false),
                AudioInputDeviceInfo(uid: "built-in-mic", name: "MacBook Microphone", deviceID: 82, isBuiltIn: true),
            ]
        )
        let routeQueue = DispatchQueue(label: "test.dictation-audio-route.immediate-selected-input")
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: routeQueue,
            observesDefaultOutputChanges: false
        )
        // Warm the UID-to-device cache, then prevent the setter's asynchronous
        // verification from hiding whether its synchronous cache update works.
        routeQueue.sync {}
        routeQueue.suspend()
        defer {
            routeQueue.resume()
            routeQueue.sync {}
        }
        let inspectionCountBeforeSelection = inspector.inspectionCallCount

        controller.selectedInputDeviceUID = "external-mic"

        #expect(controller.preferredInputDeviceIDForMeeting() == 91)
        let externalSnapshot = controller.meetingInputRouteSnapshot()
        #expect(externalSnapshot.selectedInputDeviceUID == "external-mic")
        #expect(externalSnapshot.selectedInputDeviceResolved)
        #expect(externalSnapshot.preferredInputDeviceName == "External Mic")

        controller.selectedInputDeviceUID = "built-in-mic"

        #expect(controller.preferredInputDeviceIDForMeeting() == nil)
        let builtInSnapshot = controller.meetingInputRouteSnapshot()
        #expect(builtInSnapshot.selectedInputDeviceUID == "built-in-mic")
        #expect(builtInSnapshot.selectedInputDeviceResolved)
        #expect(inspector.inspectionCallCount == inspectionCountBeforeSelection)
    }

    @Test("meeting keeps explicit built-in routing when another microphone is default")
    func meetingKeepsExplicitBuiltInRoutingForDifferentDefault() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .speakerLike,
            defaultInputDeviceID: 91,
            builtInInputDeviceID: 82,
            inputDevices: [
                AudioInputDeviceInfo(uid: "external-mic", name: "External Mic", deviceID: 91, isBuiltIn: false),
                AudioInputDeviceInfo(uid: "built-in-mic", name: "MacBook Microphone", deviceID: 82, isBuiltIn: true),
            ]
        )
        let routeQueue = DispatchQueue(label: "test.dictation-audio-route.meeting-nondefault-built-in")
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: routeQueue,
            observesDefaultOutputChanges: false
        )
        routeQueue.sync {}

        #expect(controller.preferredInputDeviceIDForMeeting() == 82)
        let snapshot = controller.meetingInputRouteSnapshot()
        #expect(snapshot.preferredInputDeviceID == 82)
        #expect(snapshot.preferredInputDeviceName == "MacBook Microphone")
        #expect(snapshot.defaultInputDeviceName == "External Mic")
    }

    @Test("meeting route cache tolerates duplicate device IDs")
    func meetingRouteCacheToleratesDuplicateDeviceIDs() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .speakerLike,
            defaultInputDeviceID: 91,
            builtInInputDeviceID: 82,
            inputDevices: [
                AudioInputDeviceInfo(uid: "external-mic", name: "External Mic", deviceID: 91, isBuiltIn: false),
                AudioInputDeviceInfo(uid: "duplicate-mic", name: "Duplicate Mic", deviceID: 91, isBuiltIn: false),
                AudioInputDeviceInfo(uid: "built-in-mic", name: "MacBook Microphone", deviceID: 82, isBuiltIn: true),
            ]
        )
        let routeQueue = DispatchQueue(label: "test.dictation-audio-route.duplicate-device-ids")
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: routeQueue,
            observesDefaultOutputChanges: false
        )
        routeQueue.sync {}

        #expect(controller.meetingInputRouteSnapshot().defaultInputDeviceName == "External Mic")
    }

    @Test("meeting route cache follows selected microphone unplug and reconnect")
    func meetingRouteCacheFollowsSelectedMicrophoneHotPlug() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .speakerLike,
            defaultInputDeviceID: 82,
            builtInInputDeviceID: 82,
            inputDevices: [
                AudioInputDeviceInfo(uid: "external-mic", name: "External Mic", deviceID: 91, isBuiltIn: false),
                AudioInputDeviceInfo(uid: "built-in-mic", name: "MacBook Microphone", deviceID: 82, isBuiltIn: true),
            ]
        )
        let routeQueue = DispatchQueue(label: "test.dictation-audio-route.selected-input-hot-plug")
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: routeQueue,
            observesDefaultOutputChanges: false
        )
        controller.selectedInputDeviceUID = "external-mic"
        routeQueue.sync {}

        #expect(controller.preferredInputDeviceIDForMeeting() == 91)
        #expect(controller.meetingInputRouteSnapshot().selectedInputDeviceResolved)

        inspector.inputDevices.removeAll { $0.uid == "external-mic" }
        controller.refreshRouteCache(notifyEvenIfPreferredUnchanged: true)
        routeQueue.sync {}

        #expect(controller.preferredInputDeviceIDForMeeting() == nil)
        #expect(!controller.meetingInputRouteSnapshot().selectedInputDeviceResolved)

        inspector.inputDevices.append(
            AudioInputDeviceInfo(uid: "external-mic", name: "External Mic", deviceID: 92, isBuiltIn: false)
        )
        controller.refreshRouteCache(notifyEvenIfPreferredUnchanged: true)
        routeQueue.sync {}

        #expect(controller.preferredInputDeviceIDForMeeting() == 92)
        #expect(controller.meetingInputRouteSnapshot().selectedInputDeviceResolved)
    }

    @Test("synchronous route refresh clears an unavailable cached microphone")
    func synchronousRouteRefreshClearsUnavailableCachedMicrophone() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .speakerLike,
            defaultInputDeviceID: 82,
            builtInInputDeviceID: 82,
            inputDevices: [
                AudioInputDeviceInfo(uid: "external-mic", name: "External Mic", deviceID: 91, isBuiltIn: false),
                AudioInputDeviceInfo(uid: "built-in-mic", name: "MacBook Microphone", deviceID: 82, isBuiltIn: true),
            ]
        )
        let routeQueue = DispatchQueue(label: "test.dictation-audio-route.cached-input-unavailable")
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: routeQueue,
            observesDefaultOutputChanges: false
        )
        controller.selectedInputDeviceUID = "external-mic"
        routeQueue.sync {}
        #expect(controller.cachedPreferredInputDeviceIDForDictation() == 91)

        inspector.inputDevices.removeAll { $0.uid == "external-mic" }

        #expect(controller.preferredInputDeviceIDForDictation() == nil)
        #expect(controller.cachedPreferredInputDeviceIDForDictation() == nil)
        #expect(controller.preferredInputDeviceIDForMeeting() == nil)
        #expect(!controller.meetingInputRouteSnapshot().selectedInputDeviceResolved)
    }

    @Test("unavailable selected microphone falls back to automatic route policy")
    func unavailableSelectedMicrophoneFallsBackToAutomaticRoutePolicy() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .headphoneLike,
            builtInInputDeviceID: 82,
            inputDevices: [
                AudioInputDeviceInfo(uid: "built-in-mic", name: "MacBook Microphone", deviceID: 82, isBuiltIn: true),
            ]
        )
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: DispatchQueue(label: "test.dictation-audio-route.missing-selected-input"),
            observesDefaultOutputChanges: false
        )
        controller.selectedInputDeviceUID = "missing-mic"

        #expect(controller.preferredInputDeviceIDForDictation() == 82)
        #expect(controller.cachedPreferredInputDeviceIDForDictation() == 82)
    }

    @Test("system default aggregate is not treated as a selectable microphone")
    func systemDefaultAggregateIsNotSelectable() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .speakerLike,
            builtInInputDeviceID: 82,
            inputDevices: [
                AudioInputDeviceInfo(uid: "CADefaultDeviceAggregate-28219-0", name: "CADefaultDeviceAggregate-28219-0", deviceID: 91, isBuiltIn: false),
                AudioInputDeviceInfo(uid: "built-in-mic", name: "MacBook Microphone", deviceID: 82, isBuiltIn: true),
            ]
        )
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: DispatchQueue(label: "test.dictation-audio-route.system-aggregate"),
            observesDefaultOutputChanges: false
        )

        #expect(controller.availableInputDevices().map(\.uid) == ["built-in-mic"])

        controller.selectedInputDeviceUID = "CADefaultDeviceAggregate-28219-0"
        #expect(controller.preferredInputDeviceIDForDictation() == nil)
    }

    @Test("default input refresh can notify even when preferred route is unchanged")
    func defaultInputRefreshCanNotifyEvenWhenPreferredRouteIsUnchanged() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .speakerLike,
            builtInInputDeviceID: 82
        )
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: DispatchQueue(label: "test.dictation-audio-route.default-input-refresh"),
            observesDefaultOutputChanges: false
        )
        _ = controller.preferredInputDeviceIDForDictation()
        var preferredInputChanges: [AudioObjectID?] = []
        controller.onPreferredInputDeviceChanged = { preferredInputChanges.append($0) }

        controller.refreshRouteCache(notifyEvenIfPreferredUnchanged: true)
        _ = controller.preferredInputDeviceIDForDictation()

        #expect(preferredInputChanges == [nil])
    }
}

private final class FakeCoreAudioDeviceInspector: CoreAudioDeviceInspecting {
    var defaultOutputDeviceIDValue: AudioObjectID?
    var defaultInputDeviceIDValue: AudioObjectID?
    var outputRouteKindValue: AudioOutputRouteKind
    var outputIsAmbiguousBluetoothValue: Bool
    var builtInInputDeviceIDValue: AudioObjectID?
    var inputDevices: [AudioInputDeviceInfo]
    private(set) var inspectionCallCount = 0

    init(
        defaultOutputDeviceID: AudioObjectID?,
        outputRouteKind: AudioOutputRouteKind,
        outputIsAmbiguousBluetooth: Bool = false,
        defaultInputDeviceID: AudioObjectID? = nil,
        builtInInputDeviceID: AudioObjectID?,
        inputDevices: [AudioInputDeviceInfo] = []
    ) {
        self.defaultOutputDeviceIDValue = defaultOutputDeviceID
        self.defaultInputDeviceIDValue = defaultInputDeviceID
        self.outputRouteKindValue = outputRouteKind
        self.outputIsAmbiguousBluetoothValue = outputIsAmbiguousBluetooth
        self.builtInInputDeviceIDValue = builtInInputDeviceID
        self.inputDevices = inputDevices
    }

    func defaultOutputDeviceID() -> AudioObjectID? {
        inspectionCallCount += 1
        return defaultOutputDeviceIDValue
    }

    func defaultInputDeviceID() -> AudioObjectID? {
        inspectionCallCount += 1
        return defaultInputDeviceIDValue
    }

    func setDefaultInputDeviceID(_ deviceID: AudioObjectID) -> Bool {
        false
    }

    func availableInputDevices() -> [AudioInputDeviceInfo] {
        inspectionCallCount += 1
        return inputDevices.filter { !$0.uid.hasPrefix("CADefaultDeviceAggregate") }
    }

    func inputDeviceID(matchingUID uid: String) -> AudioObjectID? {
        inspectionCallCount += 1
        guard !uid.hasPrefix("CADefaultDeviceAggregate") else { return nil }
        return inputDevices.first(where: { $0.uid == uid })?.deviceID
    }

    func isDeviceAvailable(_ deviceID: AudioObjectID) -> Bool {
        true
    }

    func nominalSampleRate(for deviceID: AudioObjectID) -> Double? {
        nil
    }

    func outputRouteClassification(for deviceID: AudioObjectID) -> AudioRouteClassifier.Classification {
        inspectionCallCount += 1
        return AudioRouteClassifier.Classification(
            kind: outputRouteKindValue,
            isAmbiguousBluetooth: outputIsAmbiguousBluetoothValue
        )
    }

    func builtInInputDeviceID() -> AudioObjectID? {
        inspectionCallCount += 1
        return builtInInputDeviceIDValue
    }
}
