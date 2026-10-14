import AppKit
import CoreAudio
import Testing
@testable import MuesliNativeApp

@Suite("DictationAudioRouteController")
struct DictationAudioRouteControllerTests {
    @Test("construction and UI route reads return while HAL inspection is blocked")
    @MainActor
    func blockedInspectorDoesNotBlockUI() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10, outputRouteKind: .headphoneLike, builtInInputDeviceID: 82
        )
        inspector.onOutputInspection = {
            #expect(!Thread.isMainThread)
            entered.signal()
            #expect(release.wait(timeout: .now() + 2) == .success)
        }
        let routeQueue = DispatchQueue(label: "test.blocked-hal")
        let controller = DictationAudioRouteController(
            inspector: inspector, queue: routeQueue, observesDefaultOutputChanges: false
        )
        #expect(entered.wait(timeout: .now() + 1) == .success)
        #expect(controller.preferredInputDeviceIDForDictation() == nil)
        #expect(controller.preferredInputDeviceIDForMeeting() == nil)
        #expect(controller.availableInputDevices().isEmpty)
        #expect(controller.currentOutputRouteKindForDebug() == .unknown)
        release.signal()
        routeQueue.sync {}
        inspector.onOutputInspection = nil
        #expect(controller.preferredInputDeviceIDForDictation() == 82)
    }

    @Test("dictation prefers built-in mic for headphone output")
    func dictationPrefersBuiltInMicForHeadphoneOutput() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .headphoneLike,
            builtInInputDeviceID: 82
        )
        let routeQueue = DispatchQueue(label: "test.dictation-audio-route.headphone-like")
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: routeQueue,
            observesDefaultOutputChanges: false
        )
        routeQueue.sync {}

        #expect(controller.preferredInputDeviceIDForDictation() == 82)
        #expect(controller.cachedPreferredInputDeviceIDForDictation() == 82)
    }

    @Test("meeting with no chosen microphone follows the system default, even when it is not the built-in mic")
    func meetingFollowsTheActiveSystemInput() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .headphoneLike,
            defaultInputDeviceID: 90,
            builtInInputDeviceID: 82
        )
        let routeQueue = DispatchQueue(label: "test.dictation-audio-route.meeting-headphone-like")
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: routeQueue,
            observesDefaultOutputChanges: false
        )
        routeQueue.sync {}

        // nil means "use the system-default recorder", i.e. whichever mic is active.
        #expect(controller.preferredInputDeviceIDForMeeting() == nil)
        #expect(controller.meetingInputRouteSnapshot().preferredInputDeviceID == nil)
        #expect(controller.meetingInputRouteSnapshot().defaultInputDeviceID == 90)
        #expect(controller.meetingInputRouteSnapshot().outputRouteKind == "headphone-like")
        // Dictation keeps its own route-aware policy.
        #expect(controller.preferredInputDeviceIDForDictation() == 82)
    }

    @Test("meeting uses system default recorder when built-in mic is already default")
    func meetingUsesSystemDefaultRecorderForDefaultBuiltInMic() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .speakerLike,
            defaultInputDeviceID: 82,
            builtInInputDeviceID: 82
        )
        let routeQueue = DispatchQueue(label: "test.dictation-audio-route.meeting-default-built-in")
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: routeQueue,
            observesDefaultOutputChanges: false
        )
        routeQueue.sync {}

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
        routeQueue.sync {}
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
        let routeQueue = DispatchQueue(label: "test.dictation-audio-route.speaker-like")
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: routeQueue,
            observesDefaultOutputChanges: false
        )
        routeQueue.sync {}

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
        let routeQueue = DispatchQueue(label: "test.dictation-audio-route.speaker-like-risky-input")
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: routeQueue,
            observesDefaultOutputChanges: false
        )
        routeQueue.sync {}

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
        let routeQueue = DispatchQueue(label: "test.dictation-audio-route.unknown")
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: routeQueue,
            observesDefaultOutputChanges: false
        )
        routeQueue.sync {}

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
        let routeQueue = DispatchQueue(label: "test.dictation-audio-route.unknown-non-bluetooth")
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: routeQueue,
            observesDefaultOutputChanges: false
        )
        routeQueue.sync {}

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
        let routeQueue = DispatchQueue(label: "test.dictation-audio-route.no-built-in")
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: routeQueue,
            observesDefaultOutputChanges: false
        )
        routeQueue.sync {}

        #expect(controller.preferredInputDeviceIDForDictation() == nil)
        #expect(controller.cachedPreferredInputDeviceIDForDictation() == nil)
    }

    @Test("closed lid reports the built-in mic as unavailable")
    func closedLidReportsBuiltInMicUnavailable() {
        let inspector = CoreAudioDeviceInspector(isLidClosed: { true })

        #expect(inspector.builtInInputDeviceID() == nil)
    }

    @Test("screen changes refresh automatic routes when the lid closes and reopens")
    func screenChangesRefreshLidAvailability() async throws {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .headphoneLike,
            defaultInputDeviceID: 110,
            builtInInputDeviceID: 97
        )
        let routeQueue = DispatchQueue(label: "test.dictation-audio-route.lid-transition")
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: routeQueue,
            routeChangeSettleDelay: 0,
            routeChangeMaximumDelay: 0
        )
        routeQueue.sync {}
        #expect(controller.cachedPreferredInputDeviceIDForDictation() == 97)
        #expect(controller.preferredInputDeviceIDForMeeting() == 97)

        // The audio device graph and default input stay unchanged across lid transitions.
        for builtInID: AudioObjectID? in [nil, 97] {
            routeQueue.sync { inspector.builtInInputDeviceIDValue = builtInID }
            NotificationCenter.default.post(
                name: NSApplication.didChangeScreenParametersNotification, object: nil
            )
            try await Task.sleep(for: .milliseconds(100))
            routeQueue.sync {}
            #expect(controller.cachedPreferredInputDeviceIDForDictation() == builtInID)
            #expect(controller.preferredInputDeviceIDForMeeting() == builtInID)
        }
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
        let routeQueue = DispatchQueue(label: "test.dictation-audio-route.selected-input")
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: routeQueue,
            observesDefaultOutputChanges: false
        )
        routeQueue.sync {}
        controller.selectedInputDeviceUID = "external-mic"

        #expect(controller.preferredInputDeviceIDForDictation() == 91)
        #expect(controller.cachedPreferredInputDeviceIDForDictation() == 91)
        // The dictation microphone does not choose the meeting microphone; with none chosen for
        // meetings, the system default recorder is used.
        #expect(controller.preferredInputDeviceIDForMeeting() == nil)
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
        routeQueue.sync {}
        controller.selectedMeetingInputDeviceUID = "external-mic"
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
        routeQueue.sync {}
        // Warm the UID-to-device cache, then prevent the setter's asynchronous
        // verification from hiding whether its synchronous cache update works.
        routeQueue.sync {}
        routeQueue.suspend()
        defer {
            routeQueue.resume()
            routeQueue.sync {}
        }
        let inspectionCountBeforeSelection = inspector.inspectionCallCount

        controller.selectedMeetingInputDeviceUID = "external-mic"

        #expect(controller.preferredInputDeviceIDForMeeting() == 91)
        let externalSnapshot = controller.meetingInputRouteSnapshot()
        #expect(externalSnapshot.selectedInputDeviceUID == "external-mic")
        #expect(externalSnapshot.selectedInputDeviceResolved)
        #expect(externalSnapshot.preferredInputDeviceName == "External Mic")

        controller.selectedMeetingInputDeviceUID = "built-in-mic"

        #expect(controller.preferredInputDeviceIDForMeeting() == nil)
        let builtInSnapshot = controller.meetingInputRouteSnapshot()
        #expect(builtInSnapshot.selectedInputDeviceUID == "built-in-mic")
        #expect(builtInSnapshot.selectedInputDeviceResolved)
        #expect(inspector.inspectionCallCount == inspectionCountBeforeSelection)
    }

    @Test("meeting follows the system default when another microphone is default")
    func meetingFollowsTheSystemDefaultWhenAnotherMicrophoneIsDefault() {
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
        routeQueue.sync {}

        #expect(controller.preferredInputDeviceIDForMeeting() == nil)
        let snapshot = controller.meetingInputRouteSnapshot()
        #expect(snapshot.preferredInputDeviceID == nil)
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
        routeQueue.sync {}
        controller.selectedMeetingInputDeviceUID = "external-mic"
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

    @Test("asynchronous route refresh clears an unavailable cached microphone")
    func asynchronousRouteRefreshClearsUnavailableCachedMicrophone() {
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
        routeQueue.sync {}
        controller.selectedInputDeviceUID = "external-mic"
        controller.selectedMeetingInputDeviceUID = "external-mic"
        routeQueue.sync {}
        #expect(controller.cachedPreferredInputDeviceIDForDictation() == 91)

        inspector.inputDevices.removeAll { $0.uid == "external-mic" }
        controller.refreshRouteAfterDictationSession()
        routeQueue.sync {}

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
        let routeQueue = DispatchQueue(label: "test.dictation-audio-route.missing-selected-input")
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: routeQueue,
            observesDefaultOutputChanges: false
        )
        routeQueue.sync {}
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
        let routeQueue = DispatchQueue(label: "test.dictation-audio-route.system-aggregate")
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: routeQueue,
            observesDefaultOutputChanges: false
        )
        routeQueue.sync {}

        #expect(controller.availableInputDevices().map(\.uid) == ["built-in-mic"])

        controller.selectedInputDeviceUID = "CADefaultDeviceAggregate-28219-0"
        #expect(controller.preferredInputDeviceIDForDictation() == nil)
    }

    @Test("settings device inventory reads use the route cache")
    func settingsDeviceInventoryReadsUseRouteCache() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .speakerLike,
            builtInInputDeviceID: 82,
            inputDevices: [
                AudioInputDeviceInfo(uid: "built-in-mic", name: "MacBook Microphone", deviceID: 82, isBuiltIn: true),
            ]
        )
        let routeQueue = DispatchQueue(label: "test.dictation-audio-route.cached-device-inventory")
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: routeQueue,
            observesDefaultOutputChanges: false
        )
        routeQueue.sync {}
        routeQueue.sync {}
        let inspectionCountBeforeRead = inspector.inspectionCallCount

        #expect(controller.cachedAvailableInputDevices().map(\.uid) == ["built-in-mic"])
        #expect(inspector.inspectionCallCount == inspectionCountBeforeRead)

        inspector.inputDevices.append(
            AudioInputDeviceInfo(uid: "external-mic", name: "External Mic", deviceID: 91, isBuiltIn: false)
        )
        controller.refreshAvailableInputDevices { _ in }
        routeQueue.sync {}

        #expect(controller.cachedAvailableInputDevices().map(\.uid) == ["built-in-mic", "external-mic"])
    }

    @Test("default input refresh can notify even when preferred route is unchanged")
    func defaultInputRefreshCanNotifyEvenWhenPreferredRouteIsUnchanged() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .speakerLike,
            builtInInputDeviceID: 82
        )
        let routeQueue = DispatchQueue(label: "test.dictation-audio-route.default-input-refresh")
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: routeQueue,
            observesDefaultOutputChanges: false
        )
        routeQueue.sync {}
        _ = controller.preferredInputDeviceIDForDictation()
        var preferredInputChanges: [AudioObjectID?] = []
        controller.onPreferredInputDeviceChanged = { preferredInputChanges.append($0) }

        controller.refreshRouteCache(notifyEvenIfPreferredUnchanged: true)
        routeQueue.sync {}

        #expect(preferredInputChanges == [nil])
    }

    @Test("route change bursts coalesce into one inventory refresh and notification")
    func routeChangeBurstCoalesces() async throws {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .speakerLike,
            defaultInputDeviceID: 82,
            builtInInputDeviceID: 82
        )
        let routeQueue = DispatchQueue(label: "test.dictation-audio-route.coalesced-route-change")
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: routeQueue,
            observesDefaultOutputChanges: false,
            routeChangeSettleDelay: 0.02,
            routeChangeMaximumDelay: 0.05
        )
        routeQueue.sync {}
        routeQueue.sync {}
        let inventoryReadsBeforeBurst = inspector.availableInputDevicesCallCount
        var dictationNotifications = 0
        var meetingNotifications = 0
        controller.onPreferredInputDeviceChanged = { _ in dictationNotifications += 1 }
        controller.onMeetingPreferredInputDeviceChanged = { _ in meetingNotifications += 1 }

        controller.scheduleRouteChangeRefresh(.defaultOutput)
        controller.scheduleRouteChangeRefresh(.defaultInput)
        controller.scheduleRouteChangeRefresh(.deviceInventory)
        controller.scheduleRouteChangeRefresh(.defaultOutput)
        try await Task.sleep(for: .milliseconds(100))
        routeQueue.sync {}

        #expect(inspector.availableInputDevicesCallCount == inventoryReadsBeforeBurst + 1)
        #expect(dictationNotifications == 1)
        #expect(meetingNotifications == 1)
    }

    @Test("default device events reuse cached inventory")
    func defaultDeviceEventsReuseCachedInventory() async throws {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .speakerLike,
            defaultInputDeviceID: 82,
            builtInInputDeviceID: 82
        )
        let routeQueue = DispatchQueue(label: "test.dictation-audio-route.cached-route-change")
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: routeQueue,
            observesDefaultOutputChanges: false,
            routeChangeSettleDelay: 0.01,
            routeChangeMaximumDelay: 0.02
        )
        routeQueue.sync {}
        routeQueue.sync {}
        let inventoryReadsBeforeChange = inspector.availableInputDevicesCallCount

        controller.scheduleRouteChangeRefresh(.defaultOutput)
        controller.scheduleRouteChangeRefresh(.defaultInput)
        try await Task.sleep(for: .milliseconds(60))
        routeQueue.sync {}

        #expect(inspector.availableInputDevicesCallCount == inventoryReadsBeforeChange)
    }

    // MARK: Controller to recorder handoff
    //
    // MuesliController.installMeetingCapture seeds the recorder from preferredInputDeviceIDForMeeting(),
    // and its onMeetingPreferredInputDeviceChanged handler forwards the value through MeetingSession
    // to the recorder's preferredInputDeviceID. These tests drive the real controller and the real
    // RouteAwareMeetingMicRecorder through that same wiring, with only CoreAudio and the capture
    // graphs faked.

    @Test("a meeting with no chosen microphone starts the system default recorder, not the built-in one")
    func meetingWithNoChosenMicrophoneStartsSystemDefaultRecorder() throws {
        let rig = MeetingRouteRig(defaultInputDeviceID: 90)

        try rig.recorder.prepare()
        try rig.recorder.start()

        #expect(rig.recorder.preferredInputDeviceID == nil)
        #expect(rig.recorder.activeRecorderKindForDebug() == .systemDefault)
        #expect(rig.initial.startCalls == 1)
        rig.recorder.cancel()
        rig.recorder.waitForQuiescence()
    }

    @Test("a default input change with no chosen microphone reaches the recorder as a handoff")
    func defaultInputChangeWithNoChosenMicrophoneHandsOff() async throws {
        let rig = MeetingRouteRig(defaultInputDeviceID: 90)
        try rig.recorder.start()

        rig.setDefaultInput(91)
        rig.controller.scheduleRouteChangeRefresh(.defaultInput)

        try await rig.waitUntil { rig.replacement.startCalls == 1 }
        rig.replacement.onRawPCMSamples?([1])
        try await rig.waitUntil { rig.initial.stopCalls == 1 }
        #expect(rig.recorder.preferredInputDeviceID == nil)
        #expect(rig.recorder.activeRecorderKindForDebug() == .systemDefault)
        rig.recorder.cancel()
        rig.recorder.waitForQuiescence()
    }

    @Test("a device inventory change that leaves the default input alone does not restart the meeting microphone")
    func inventoryChangeWithSameDefaultInputDoesNotHandOff() async throws {
        let rig = MeetingRouteRig(defaultInputDeviceID: 90)
        try rig.recorder.start()

        rig.controller.scheduleRouteChangeRefresh(.deviceInventory)
        rig.controller.scheduleRouteChangeRefresh(.defaultOutput)
        try await Task.sleep(for: .milliseconds(100))
        rig.routeQueue.sync {}
        rig.recorder.waitForQuiescence()

        #expect(rig.replacement.startCalls == 0)
        #expect(rig.initial.stopCalls == 0)
        rig.recorder.cancel()
        rig.recorder.waitForQuiescence()
    }

    @Test("a default input change leaves an explicitly chosen meeting microphone alone")
    func defaultInputChangeKeepsChosenMeetingMicrophone() async throws {
        let rig = MeetingRouteRig(
            defaultInputDeviceID: 82,
            selectedMeetingMicrophone: AudioInputDeviceInfo(
                uid: "external-mic", name: "External Mic", deviceID: 91, isBuiltIn: false
            )
        )
        #expect(rig.recorder.preferredInputDeviceID == 91)
        try rig.recorder.start()

        rig.setDefaultInput(90)
        rig.controller.scheduleRouteChangeRefresh(.defaultInput)
        try await Task.sleep(for: .milliseconds(100))
        rig.routeQueue.sync {}
        rig.recorder.waitForQuiescence()

        #expect(rig.recorder.preferredInputDeviceID == 91)
        #expect(rig.recorder.activeRecorderKindForDebug() == .appScoped)
        #expect(rig.replacement.startCalls == 0)
        #expect(rig.initial.stopCalls == 0)
        rig.recorder.cancel()
        rig.recorder.waitForQuiescence()
    }
}

/// The production meeting wiring minus CoreAudio and the capture graphs.
private final class MeetingRouteRig {
    let routeQueue = DispatchQueue(label: "test.dictation-audio-route.meeting-rig")
    let inspector: FakeCoreAudioDeviceInspector
    let controller: DictationAudioRouteController
    let recorder: RouteAwareMeetingMicRecorder
    /// The graph the meeting starts on, and the one a handoff builds next.
    let initial: FakeMeetingMicRecorder
    let replacement: FakeMeetingMicRecorder

    init(defaultInputDeviceID: AudioObjectID, selectedMeetingMicrophone: AudioInputDeviceInfo? = nil) {
        let builtIn = AudioInputDeviceInfo(uid: "built-in-mic", name: "MacBook Microphone", deviceID: 82, isBuiltIn: true)
        inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .headphoneLike,
            defaultInputDeviceID: defaultInputDeviceID,
            builtInInputDeviceID: 82,
            inputDevices: [builtIn] + (selectedMeetingMicrophone.map { [$0] } ?? [])
        )
        controller = DictationAudioRouteController(
            inspector: inspector,
            queue: routeQueue,
            observesDefaultOutputChanges: false,
            routeChangeSettleDelay: 0.01,
            routeChangeMaximumDelay: 0.02
        )
        routeQueue.sync {}
        routeQueue.sync {}
        if let selectedMeetingMicrophone {
            controller.selectedMeetingInputDeviceUID = selectedMeetingMicrophone.uid
            routeQueue.sync {}
        }

        let preferred = controller.preferredInputDeviceIDForMeeting()
        let initialKind: MeetingMicRecorderKind = preferred == nil ? .systemDefaultStreaming : .appScopedAudioQueue
        let initial = FakeMeetingMicRecorder(kind: initialKind)
        let replacement = FakeMeetingMicRecorder(kind: initialKind)
        self.initial = initial
        self.replacement = replacement
        let controller = self.controller
        let recorder = RouteAwareMeetingMicRecorder(
            systemDefaultRecorder: preferred == nil ? initial : nil,
            appScopedRecorder: preferred == nil ? nil : initial,
            systemDefaultRecorderFactory: { replacement },
            appScopedRecorderFactory: { replacement },
            routeSnapshotProvider: { controller.meetingInputRouteSnapshot() },
            handoffTimeout: 1,
            handoffTimeoutScheduler: { _, _ in }
        )
        // MuesliController.installMeetingCapture
        recorder.preferredInputDeviceID = preferred
        // MuesliController.onMeetingPreferredInputDeviceChanged, via MeetingSession
        controller.onMeetingPreferredInputDeviceChanged = { [weak recorder] deviceID in
            recorder?.preferredInputDeviceID = deviceID
        }
        self.recorder = recorder
    }

    func setDefaultInput(_ deviceID: AudioObjectID) {
        routeQueue.sync { inspector.defaultInputDeviceIDValue = deviceID }
    }

    func waitUntil(timeout: Duration = .seconds(5), condition: @escaping () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for the meeting microphone handoff")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class FakeCoreAudioDeviceInspector: CoreAudioDeviceInspecting {
    var onOutputInspection: (() -> Void)?
    var defaultOutputDeviceIDValue: AudioObjectID?
    var defaultInputDeviceIDValue: AudioObjectID?
    var outputRouteKindValue: AudioOutputRouteKind
    var outputIsAmbiguousBluetoothValue: Bool
    var builtInInputDeviceIDValue: AudioObjectID?
    var inputDevices: [AudioInputDeviceInfo]
    private(set) var inspectionCallCount = 0
    private(set) var availableInputDevicesCallCount = 0

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
        onOutputInspection?()
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
        availableInputDevicesCallCount += 1
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
