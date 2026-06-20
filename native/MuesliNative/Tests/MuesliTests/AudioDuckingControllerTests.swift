import CoreAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("AudioDuckingController")
struct AudioDuckingControllerTests {
    @Test("disabled setting is a no-op")
    func disabledSettingIsNoOp() {
        let client = FakeAudioDuckingDeviceClient()
        client.activityStatus = .active
        client.defaultDeviceID = 1
        client.availableDevices = [1]
        client.muteElementsByDevice[1] = [kAudioObjectPropertyElementMain]
        client.muteValues[.init(1, kAudioObjectPropertyElementMain)] = false

        let controller = makeController(client: client)
        controller.beginDictationDucking(enabled: false)
        controller.ensureCurrentDefaultDucked()
        controller.restoreDictationDucking()
        controller.waitForIdle()

        #expect(client.muteValues[.init(1, kAudioObjectPropertyElementMain)] == false)
        #expect(client.muteSetCalls.isEmpty)
    }

    @Test("inactive output is skipped")
    func inactiveOutputIsSkipped() {
        let client = FakeAudioDuckingDeviceClient()
        client.activityStatus = .inactive
        client.defaultDeviceID = 1
        client.availableDevices = [1]
        client.muteElementsByDevice[1] = [kAudioObjectPropertyElementMain]
        client.muteValues[.init(1, kAudioObjectPropertyElementMain)] = false

        let controller = makeController(client: client)
        controller.beginDictationDucking(enabled: true)
        controller.restoreDictationDucking()
        controller.waitForIdle()

        #expect(client.muteValues[.init(1, kAudioObjectPropertyElementMain)] == false)
        #expect(client.muteSetCalls.isEmpty)
    }

    @Test("headphone output is skipped")
    func headphoneOutputIsSkipped() {
        let client = FakeAudioDuckingDeviceClient()
        client.activityStatus = .active
        client.outputRouteKind = .headphoneLike
        client.defaultDeviceID = 1
        client.availableDevices = [1]
        client.muteElementsByDevice[1] = [kAudioObjectPropertyElementMain]
        client.muteValues[.init(1, kAudioObjectPropertyElementMain)] = false

        let controller = makeController(client: client)
        controller.beginDictationDucking(enabled: true)
        controller.ensureCurrentDefaultDucked()
        controller.restoreDictationDucking()
        controller.waitForIdle()

        #expect(client.muteValues[.init(1, kAudioObjectPropertyElementMain)] == false)
        #expect(client.muteSetCalls.isEmpty)
    }

    @Test("active output mutes and restores")
    func activeOutputMutesAndRestores() {
        let client = FakeAudioDuckingDeviceClient()
        client.activityStatus = .active
        client.defaultDeviceID = 1
        client.availableDevices = [1]
        client.muteElementsByDevice[1] = [kAudioObjectPropertyElementMain]
        client.muteValues[.init(1, kAudioObjectPropertyElementMain)] = false

        let controller = makeController(client: client)
        controller.beginDictationDucking(enabled: true)
        controller.waitForIdle()
        #expect(client.muteValues[.init(1, kAudioObjectPropertyElementMain)] == true)

        controller.restoreDictationDucking()
        controller.waitForIdle()

        #expect(client.muteValues[.init(1, kAudioObjectPropertyElementMain)] == false)
        #expect(client.muteSetCalls == [
            .init(deviceID: 1, element: kAudioObjectPropertyElementMain, value: true),
            .init(deviceID: 1, element: kAudioObjectPropertyElementMain, value: false),
        ])
    }

    @Test("unknown activity fails open and mutes")
    func unknownActivityFailsOpenAndMutes() {
        let client = FakeAudioDuckingDeviceClient()
        client.activityStatus = .unknown
        client.defaultDeviceID = 1
        client.availableDevices = [1]
        client.muteElementsByDevice[1] = [kAudioObjectPropertyElementMain]
        client.muteValues[.init(1, kAudioObjectPropertyElementMain)] = false

        let controller = makeController(client: client)
        controller.beginDictationDucking(enabled: true)
        controller.waitForIdle()

        #expect(client.muteValues[.init(1, kAudioObjectPropertyElementMain)] == true)
    }

    @Test("already-muted output remains muted after restore")
    func alreadyMutedOutputRemainsMutedAfterRestore() {
        let client = FakeAudioDuckingDeviceClient()
        client.activityStatus = .active
        client.defaultDeviceID = 1
        client.availableDevices = [1]
        client.muteElementsByDevice[1] = [kAudioObjectPropertyElementMain]
        client.muteValues[.init(1, kAudioObjectPropertyElementMain)] = true

        let controller = makeController(client: client)
        controller.beginDictationDucking(enabled: true)
        controller.waitForIdle()
        controller.restoreDictationDucking()
        controller.waitForIdle()

        #expect(client.muteValues[.init(1, kAudioObjectPropertyElementMain)] == true)
        #expect(client.muteSetCalls.isEmpty)
    }

    @Test("unsupported mute falls back to volume restore")
    func unsupportedMuteFallsBackToVolumeRestore() {
        let client = FakeAudioDuckingDeviceClient()
        client.activityStatus = .active
        client.defaultDeviceID = 1
        client.availableDevices = [1]
        client.volumeElementsByDevice[1] = [kAudioObjectPropertyElementMain]
        client.volumeValues[.init(1, kAudioObjectPropertyElementMain)] = 0.75

        let controller = makeController(client: client)
        controller.beginDictationDucking(enabled: true)
        controller.waitForIdle()
        #expect(client.volumeValues[.init(1, kAudioObjectPropertyElementMain)] == 0)

        controller.restoreDictationDucking()
        controller.waitForIdle()

        #expect(client.volumeValues[.init(1, kAudioObjectPropertyElementMain)] == 0.75)
    }

    @Test("user volume changes during dictation are not overwritten")
    func userVolumeChangeIsNotOverwritten() {
        let client = FakeAudioDuckingDeviceClient()
        client.activityStatus = .active
        client.defaultDeviceID = 1
        client.availableDevices = [1]
        client.volumeElementsByDevice[1] = [kAudioObjectPropertyElementMain]
        client.volumeValues[.init(1, kAudioObjectPropertyElementMain)] = 0.75

        let controller = makeController(client: client)
        controller.beginDictationDucking(enabled: true)
        controller.waitForIdle()
        client.volumeValues[.init(1, kAudioObjectPropertyElementMain)] = 0.3

        controller.restoreDictationDucking()
        controller.waitForIdle()

        #expect(client.volumeValues[.init(1, kAudioObjectPropertyElementMain)] == 0.3)
    }

    @Test("default output changes restore only touched devices")
    func defaultOutputChangesRestoreTouchedDevices() {
        let client = FakeAudioDuckingDeviceClient()
        client.activityStatus = .active
        client.defaultDeviceID = 1
        client.availableDevices = [1, 2, 3]
        client.muteElementsByDevice[1] = [kAudioObjectPropertyElementMain]
        client.muteElementsByDevice[2] = [kAudioObjectPropertyElementMain]
        client.muteElementsByDevice[3] = [kAudioObjectPropertyElementMain]
        client.muteValues[.init(1, kAudioObjectPropertyElementMain)] = false
        client.muteValues[.init(2, kAudioObjectPropertyElementMain)] = false
        client.muteValues[.init(3, kAudioObjectPropertyElementMain)] = false

        let controller = makeController(client: client)
        controller.beginDictationDucking(enabled: true)
        controller.waitForIdle()
        client.defaultDeviceID = 2
        controller.ensureCurrentDefaultDucked()
        controller.waitForIdle()
        client.defaultDeviceID = 3

        controller.restoreDictationDucking()
        controller.waitForIdle()

        #expect(client.muteValues[.init(1, kAudioObjectPropertyElementMain)] == false)
        #expect(client.muteValues[.init(2, kAudioObjectPropertyElementMain)] == false)
        #expect(client.muteValues[.init(3, kAudioObjectPropertyElementMain)] == false)
        #expect(client.muteSetCalls.map(\.deviceID).sorted() == [1, 1, 2, 2])
    }

    @Test("disconnected devices are skipped on restore")
    func disconnectedDevicesAreSkippedOnRestore() {
        let client = FakeAudioDuckingDeviceClient()
        client.activityStatus = .active
        client.defaultDeviceID = 1
        client.availableDevices = [1]
        client.muteElementsByDevice[1] = [kAudioObjectPropertyElementMain]
        client.muteValues[.init(1, kAudioObjectPropertyElementMain)] = false

        let controller = makeController(client: client)
        controller.beginDictationDucking(enabled: true)
        controller.waitForIdle()
        client.availableDevices = []

        controller.restoreDictationDucking()
        controller.waitForIdle()

        #expect(client.muteValues[.init(1, kAudioObjectPropertyElementMain)] == true)
        #expect(client.muteSetCalls == [
            .init(deviceID: 1, element: kAudioObjectPropertyElementMain, value: true),
        ])
    }

    @Test("restore waits briefly for codec sample rate to stabilize")
    func restoreWaitsForCodecStabilization() {
        let client = FakeAudioDuckingDeviceClient()
        client.activityStatus = .active
        client.defaultDeviceID = 1
        client.availableDevices = [1]
        client.muteElementsByDevice[1] = [kAudioObjectPropertyElementMain]
        client.muteValues[.init(1, kAudioObjectPropertyElementMain)] = false
        client.sampleRateValues[1] = [48_000, 24_000, 48_000]

        let controller = AudioDuckingController(
            client: client,
            queue: DispatchQueue(label: "test.audio-ducking.codec"),
            stabilizationTimeout: 0.1,
            stabilizationPollInterval: 0.001
        )
        controller.beginDictationDucking(enabled: true)
        controller.waitForIdle()
        controller.restoreDictationDucking()
        Thread.sleep(forTimeInterval: 0.02)
        controller.waitForIdle()

        #expect(client.sampleRateReadCount[1, default: 0] >= 3)
        #expect(client.muteValues[.init(1, kAudioObjectPropertyElementMain)] == false)
    }

    @Test("rapid second dictation drops cancelled restore completions")
    func rapidSecondDictationDropsCancelledRestoreCompletions() {
        let client = FakeAudioDuckingDeviceClient()
        client.activityStatus = .active
        client.defaultDeviceID = 1
        client.availableDevices = [1]
        client.muteElementsByDevice[1] = [kAudioObjectPropertyElementMain]
        client.muteValues[.init(1, kAudioObjectPropertyElementMain)] = false
        client.sampleRateValues[1] = [48_000, 24_000, 24_000, 24_000]

        let controller = AudioDuckingController(
            client: client,
            queue: DispatchQueue(label: "test.audio-ducking.rapid-turnover"),
            stabilizationTimeout: 0.05,
            stabilizationPollInterval: 0.001
        )

        controller.beginDictationDucking(enabled: true)
        controller.waitForIdle()
        var restoreCompletionCount = 0
        controller.restoreDictationDucking {
            restoreCompletionCount += 1
        }
        controller.beginDictationDucking(enabled: true)
        controller.waitForIdle()
        Thread.sleep(forTimeInterval: 0.07)
        controller.waitForIdle()

        #expect(restoreCompletionCount == 0)
        #expect(client.muteValues[.init(1, kAudioObjectPropertyElementMain)] == true)
        #expect(client.muteSetCalls == [
            .init(deviceID: 1, element: kAudioObjectPropertyElementMain, value: true),
        ])

        controller.restoreDictationDucking()
        Thread.sleep(forTimeInterval: 0.07)
        controller.waitForIdle()

        #expect(restoreCompletionCount == 0)
        #expect(client.muteValues[.init(1, kAudioObjectPropertyElementMain)] == false)
        #expect(client.muteSetCalls == [
            .init(deviceID: 1, element: kAudioObjectPropertyElementMain, value: true),
            .init(deviceID: 1, element: kAudioObjectPropertyElementMain, value: false),
        ])
    }

    @Test("disabling ducking during pending restore preserves restore completions")
    func disablingDuckingDuringPendingRestorePreservesRestoreCompletions() {
        let client = FakeAudioDuckingDeviceClient()
        client.activityStatus = .active
        client.defaultDeviceID = 1
        client.availableDevices = [1]
        client.muteElementsByDevice[1] = [kAudioObjectPropertyElementMain]
        client.muteValues[.init(1, kAudioObjectPropertyElementMain)] = false
        client.sampleRateValues[1] = [48_000, 24_000, 24_000, 24_000]

        let controller = AudioDuckingController(
            client: client,
            queue: DispatchQueue(label: "test.audio-ducking.disable-pending"),
            stabilizationTimeout: 0.05,
            stabilizationPollInterval: 0.001
        )

        controller.beginDictationDucking(enabled: true)
        controller.waitForIdle()
        var restoreCompletionCount = 0
        controller.restoreDictationDucking {
            restoreCompletionCount += 1
        }
        controller.beginDictationDucking(enabled: false)
        Thread.sleep(forTimeInterval: 0.07)
        controller.waitForIdle()

        #expect(restoreCompletionCount == 1)
        #expect(client.muteValues[.init(1, kAudioObjectPropertyElementMain)] == false)
        #expect(client.muteSetCalls == [
            .init(deviceID: 1, element: kAudioObjectPropertyElementMain, value: true),
            .init(deviceID: 1, element: kAudioObjectPropertyElementMain, value: false),
        ])
    }

    @Test("rapid second dictation preserves original volume while restore is pending")
    func rapidSecondDictationPreservesOriginalVolumeWhileRestoreIsPending() {
        let client = FakeAudioDuckingDeviceClient()
        client.activityStatus = .active
        client.defaultDeviceID = 1
        client.availableDevices = [1]
        client.volumeElementsByDevice[1] = [kAudioObjectPropertyElementMain]
        client.volumeValues[.init(1, kAudioObjectPropertyElementMain)] = 0.65
        client.sampleRateValues[1] = [48_000, 24_000, 24_000, 24_000]

        let controller = AudioDuckingController(
            client: client,
            queue: DispatchQueue(label: "test.audio-ducking.rapid-volume-turnover"),
            stabilizationTimeout: 0.05,
            stabilizationPollInterval: 0.001
        )

        controller.beginDictationDucking(enabled: true)
        controller.waitForIdle()
        controller.restoreDictationDucking()
        controller.beginDictationDucking(enabled: true)
        controller.waitForIdle()
        Thread.sleep(forTimeInterval: 0.07)
        controller.waitForIdle()

        #expect(client.volumeValues[.init(1, kAudioObjectPropertyElementMain)] == 0)

        controller.restoreDictationDucking()
        Thread.sleep(forTimeInterval: 0.07)
        controller.waitForIdle()

        #expect(client.volumeValues[.init(1, kAudioObjectPropertyElementMain)] == 0.65)
        #expect(client.volumeSetCalls == [
            .init(deviceID: 1, element: kAudioObjectPropertyElementMain, value: 0),
            .init(deviceID: 1, element: kAudioObjectPropertyElementMain, value: 0.65),
        ])
    }

    private func makeController(client: FakeAudioDuckingDeviceClient) -> AudioDuckingController {
        AudioDuckingController(
            client: client,
            queue: DispatchQueue(label: "test.audio-ducking.\(UUID().uuidString)"),
            stabilizationTimeout: 0,
            stabilizationPollInterval: 0
        )
    }
}

private struct DeviceElement: Hashable {
    let deviceID: AudioObjectID
    let element: AudioObjectPropertyElement

    init(_ deviceID: AudioObjectID, _ element: AudioObjectPropertyElement) {
        self.deviceID = deviceID
        self.element = element
    }
}

private struct MuteSetCall: Equatable {
    let deviceID: AudioObjectID
    let element: AudioObjectPropertyElement
    let value: Bool
}

private struct VolumeSetCall: Equatable {
    let deviceID: AudioObjectID
    let element: AudioObjectPropertyElement
    let value: Float32
}

private final class FakeAudioDuckingDeviceClient: AudioDuckingDeviceClient {
    var activityStatus: AudioOutputActivityStatus = .inactive
    var outputRouteKind: AudioOutputRouteKind = .speakerLike
    var defaultDeviceID: AudioObjectID?
    var availableDevices = Set<AudioObjectID>()
    var muteElementsByDevice: [AudioObjectID: [AudioObjectPropertyElement]] = [:]
    var muteValues: [DeviceElement: Bool] = [:]
    var volumeElementsByDevice: [AudioObjectID: [AudioObjectPropertyElement]] = [:]
    var volumeValues: [DeviceElement: Float32] = [:]
    var sampleRateValues: [AudioObjectID: [Double]] = [:]
    var sampleRateReadCount: [AudioObjectID: Int] = [:]
    var muteSetCalls: [MuteSetCall] = []
    var volumeSetCalls: [VolumeSetCall] = []

    func outputActivityStatus() -> AudioOutputActivityStatus {
        activityStatus
    }

    func defaultOutputRouteKind() -> AudioOutputRouteKind {
        outputRouteKind
    }

    func defaultOutputDeviceID() -> AudioObjectID? {
        defaultDeviceID
    }

    func isDeviceAvailable(_ deviceID: AudioObjectID) -> Bool {
        availableDevices.contains(deviceID)
    }

    func nominalSampleRate(for deviceID: AudioObjectID) -> Double? {
        sampleRateReadCount[deviceID, default: 0] += 1
        guard let values = sampleRateValues[deviceID], !values.isEmpty else { return nil }
        let index = min(sampleRateReadCount[deviceID, default: 1] - 1, values.count - 1)
        return values[index]
    }

    func muteElements(for deviceID: AudioObjectID) -> [AudioObjectPropertyElement] {
        muteElementsByDevice[deviceID] ?? []
    }

    func isMuted(deviceID: AudioObjectID, element: AudioObjectPropertyElement) -> Bool? {
        muteValues[.init(deviceID, element)]
    }

    func setMuted(_ muted: Bool, deviceID: AudioObjectID, element: AudioObjectPropertyElement) -> Bool {
        guard isDeviceAvailable(deviceID) else { return false }
        muteValues[.init(deviceID, element)] = muted
        muteSetCalls.append(MuteSetCall(deviceID: deviceID, element: element, value: muted))
        return true
    }

    func volumeElements(for deviceID: AudioObjectID) -> [AudioObjectPropertyElement] {
        volumeElementsByDevice[deviceID] ?? []
    }

    func volume(deviceID: AudioObjectID, element: AudioObjectPropertyElement) -> Float32? {
        volumeValues[.init(deviceID, element)]
    }

    func setVolume(_ volume: Float32, deviceID: AudioObjectID, element: AudioObjectPropertyElement) -> Bool {
        guard isDeviceAvailable(deviceID) else { return false }
        volumeValues[.init(deviceID, element)] = volume
        volumeSetCalls.append(VolumeSetCall(deviceID: deviceID, element: element, value: volume))
        return true
    }
}
