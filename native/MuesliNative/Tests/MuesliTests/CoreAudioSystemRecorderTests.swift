import CoreAudio
import Testing
@testable import MuesliNativeApp

@Suite("CoreAudioSystemRecorder")
struct CoreAudioSystemRecorderTests {

    @Test("global tap description captures process mix except Muesli")
    func globalTapDescriptionExcludesSelfAudio() {
        let tapDescription = CoreAudioSystemRecorder.makeGlobalTapDescription(
            excludingProcessID: 123,
            name: "Muesli Global Test Tap"
        )

        #expect(tapDescription.name == "Muesli Global Test Tap")
        #expect(tapDescription.deviceUID == nil)
        #expect(tapDescription.stream == nil)
        #expect(tapDescription.processes == [123])
        #expect(tapDescription.isPrivate)
        #expect(tapDescription.muteBehavior == .unmuted)
    }

    @Test("aggregate device description includes tap with drift compensation")
    func aggregateDeviceDescriptionIncludesTap() throws {
        let description = CoreAudioSystemRecorder.makeAggregateDeviceDescription(
            tapUID: "tap-uid",
            aggregateUID: "aggregate-uid"
        )

        #expect(description[kAudioAggregateDeviceNameKey] as? String == "Muesli System Audio")
        #expect(description[kAudioAggregateDeviceUIDKey] as? String == "aggregate-uid")
        #expect(description[kAudioAggregateDeviceIsPrivateKey] as? Bool == true)
        #expect(description[kAudioAggregateDeviceTapAutoStartKey] as? Bool == true)

        let taps = try #require(description[kAudioAggregateDeviceTapListKey] as? [[String: Any]])
        let tap = try #require(taps.first)
        #expect(tap[kAudioSubTapUIDKey] as? String == "tap-uid")
        #expect(tap[kAudioSubTapDriftCompensationKey] as? Bool == true)
    }
}
