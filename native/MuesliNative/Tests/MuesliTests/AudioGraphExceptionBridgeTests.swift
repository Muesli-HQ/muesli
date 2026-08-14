import AVFoundation
import AudioGraphExceptionBridge
import CoreAudio
import Testing

@Suite("AVFAudio exception boundary")
struct AudioGraphExceptionBridgeTests {
    @Test("input state reads return a format or a bridged error")
    func inputStateReadIsContained() {
        let state = MuesliAudioGraphReadInputState(AVAudioEngine())

        #expect(state.outputFormat != nil || state.error != nil)
    }

    @Test("invalid input routing returns an error instead of escaping the boundary")
    func invalidInputRouteIsContained() {
        let error = MuesliAudioGraphSetInputDevice(AVAudioEngine(), AudioObjectID.max)

        #expect(error != nil)
    }
}
