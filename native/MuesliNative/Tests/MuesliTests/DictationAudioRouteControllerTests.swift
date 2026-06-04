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
        defaultOutputDeviceIDValue
    }

    func defaultInputDeviceID() -> AudioObjectID? {
        defaultInputDeviceIDValue
    }

    func setDefaultInputDeviceID(_ deviceID: AudioObjectID) -> Bool {
        false
    }

    func availableInputDevices() -> [AudioInputDeviceInfo] {
        inputDevices.filter { !$0.uid.hasPrefix("CADefaultDeviceAggregate") }
    }

    func inputDeviceID(matchingUID uid: String) -> AudioObjectID? {
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
        AudioRouteClassifier.Classification(
            kind: outputRouteKindValue,
            isAmbiguousBluetooth: outputIsAmbiguousBluetoothValue
        )
    }

    func builtInInputDeviceID() -> AudioObjectID? {
        builtInInputDeviceIDValue
    }
}
