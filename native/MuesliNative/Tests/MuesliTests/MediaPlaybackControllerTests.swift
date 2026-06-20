import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MediaPlaybackController")
struct MediaPlaybackControllerTests {
    @Test("disabled setting is a no-op")
    func disabledSettingIsNoOp() {
        let client = FakeMediaPlaybackClient(activityStatus: .active)
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: false, routeKind: .speakerLike)
        controller.restoreDictationMediaPause()
        controller.waitForIdle()

        #expect(client.toggleCalls == 0)
    }

    @Test("inactive output is skipped")
    func inactiveOutputIsSkipped() {
        let client = FakeMediaPlaybackClient(activityStatus: .inactive)
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)
        controller.waitForIdle()

        #expect(client.toggleCalls == 0)
    }

    @Test("headphone output is skipped")
    func headphoneOutputIsSkipped() {
        let client = FakeMediaPlaybackClient(activityStatus: .active)
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: true, routeKind: .headphoneLike)
        controller.waitForIdle()

        #expect(client.toggleCalls == 0)
    }

    @Test("speaker active output pauses and restores")
    func speakerActiveOutputPausesAndRestores() {
        let client = FakeMediaPlaybackClient(activityStatus: .active)
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)
        controller.waitForIdle()
        #expect(client.toggleCalls == 1)

        client.activityStatus = .inactive
        controller.restoreDictationMediaPause()
        controller.waitForIdle()

        #expect(client.toggleCalls == 2)
    }

    @Test("restore does not toggle if user already started playback")
    func restoreDoesNotToggleActivePlayback() {
        let client = FakeMediaPlaybackClient(activityStatus: .active)
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)
        controller.waitForIdle()
        controller.restoreDictationMediaPause()
        controller.waitForIdle()

        #expect(client.toggleCalls == 1)
    }

    @Test("restore resumes when output activity is unknown")
    func restoreResumesWhenActivityIsUnknown() {
        let client = FakeMediaPlaybackClient(activityStatus: .active)
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)
        controller.waitForIdle()
        client.activityStatus = .unknown
        controller.restoreDictationMediaPause()
        controller.waitForIdle()

        #expect(client.toggleCalls == 2)
    }

    @Test("duplicate begin only pauses once")
    func duplicateBeginOnlyPausesOnce() {
        let client = FakeMediaPlaybackClient(activityStatus: .active)
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)
        controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)
        controller.waitForIdle()

        #expect(client.toggleCalls == 1)
    }

    private func makeController(client: FakeMediaPlaybackClient) -> MediaPlaybackController {
        MediaPlaybackController(
            client: client,
            queue: DispatchQueue(label: "test.media-playback")
        )
    }
}

private final class FakeMediaPlaybackClient: MediaPlaybackClient {
    var activityStatus: AudioOutputActivityStatus
    var toggleCalls = 0

    init(activityStatus: AudioOutputActivityStatus) {
        self.activityStatus = activityStatus
    }

    func outputActivityStatus() -> AudioOutputActivityStatus {
        activityStatus
    }

    func sendMediaPlayPauseToggle() {
        toggleCalls += 1
    }
}
