import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MediaPlaybackController")
struct MediaPlaybackControllerTests {
    @Test("disabled setting is a no-op")
    func disabledSettingIsNoOp() {
        let client = FakeMediaPlaybackClient(playbackState: .playing)
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: false, routeKind: .speakerLike)
        controller.restoreDictationMediaPause()
        controller.waitForIdle()

        #expect(client.toggles.isEmpty)
    }

    @Test("already-paused media is left alone throughout")
    func alreadyPausedMediaIsLeftAlone() {
        // Regression guard for issue #225. A paused video still reports its
        // audio pipeline as active, so the decision must come from now-playing
        // state. Neither the press nor the release may toggle, or the paused
        // media starts playing.
        let client = FakeMediaPlaybackClient(playbackState: .notPlaying)
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)
        controller.waitForIdle()
        controller.restoreDictationMediaPause()
        controller.waitForIdle()

        #expect(client.toggles.isEmpty)
        #expect(client.playbackState == .notPlaying)
    }

    @Test("unknown playback state never toggles")
    func unknownPlaybackStateNeverToggles() {
        // A toggle is as likely to start silent media as to stop playing media,
        // so an unreadable state must not be guessed at.
        let client = FakeMediaPlaybackClient(playbackState: .unknown)
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)
        controller.waitForIdle()
        controller.restoreDictationMediaPause()
        controller.waitForIdle()

        #expect(client.toggles.isEmpty)
    }

    @Test("playing media pauses and resumes")
    func playingMediaPausesAndResumes() {
        let client = FakeMediaPlaybackClient(playbackState: .playing)
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)
        controller.waitForIdle()
        #expect(client.toggles == [.pause])
        #expect(client.playbackState == .notPlaying)

        controller.restoreDictationMediaPause()
        controller.waitForIdle()

        #expect(client.toggles == [.pause, .play])
        #expect(client.playbackState == .playing)
    }

    @Test("a dropped toggle is retried until the state confirms")
    func droppedToggleIsRetried() {
        // The HID play/pause key is fire-and-forget: there is no delivery
        // acknowledgement, and a lost event is otherwise invisible.
        let client = FakeMediaPlaybackClient(playbackState: .playing)
        client.togglesToDrop = 1
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)
        controller.waitForIdle()

        #expect(client.toggles == [.pause, .pause])
        #expect(client.playbackState == .notPlaying)
    }

    @Test("a toggle dropped on resume is retried")
    func droppedResumeToggleIsRetried() {
        let client = FakeMediaPlaybackClient(playbackState: .playing)
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)
        controller.waitForIdle()
        #expect(client.playbackState == .notPlaying)

        client.togglesToDrop = 1
        controller.restoreDictationMediaPause()
        controller.waitForIdle()

        #expect(client.toggles == [.pause, .play, .play])
        #expect(client.playbackState == .playing)
    }

    @Test("resume is not sent when the user already resumed playback")
    func resumeIsSkippedWhenUserAlreadyResumed() {
        // Verify-before-toggle means a manual resume during dictation does not
        // get toggled back off on release.
        let client = FakeMediaPlaybackClient(playbackState: .playing)
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)
        controller.waitForIdle()
        #expect(client.toggles == [.pause])

        client.playbackState = .playing
        controller.restoreDictationMediaPause()
        controller.waitForIdle()

        #expect(client.toggles == [.pause])
        #expect(client.playbackState == .playing)
    }

    @Test("repeated pause and resume cycles remain reusable")
    func repeatedCyclesRemainReusable() {
        let client = FakeMediaPlaybackClient(playbackState: .playing)
        let controller = makeController(client: client)

        for _ in 0 ..< 4 {
            controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)
            controller.waitForIdle()
            #expect(client.playbackState == .notPlaying)

            controller.restoreDictationMediaPause()
            controller.waitForIdle()
            #expect(client.playbackState == .playing)
        }

        #expect(client.toggles == [.pause, .play, .pause, .play, .pause, .play, .pause, .play])
    }

    @Test("a missed restore self-heals on the next dictation")
    func missedRestoreSelfHeals() {
        // If a dictation ends without a restore — cancelled, errored, or a
        // release we never saw — the controller must not stay latched in its
        // paused state and silently stop pausing forever after.
        let client = FakeMediaPlaybackClient(playbackState: .playing)
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)
        controller.waitForIdle()
        #expect(client.toggles == [.pause])

        // No restore. The user resumes playback by hand.
        client.playbackState = .playing

        controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)
        controller.waitForIdle()

        #expect(client.toggles == [.pause, .pause])
        #expect(client.playbackState == .notPlaying)
    }

    @Test("a dictation starting during an in-flight resume does not strand media paused")
    func dictationDuringInFlightResumeDoesNotStrandMedia() {
        // The resume begins with a state query, so a dictation starting inside
        // that window cancels it before any toggle is sent. The next begin then
        // reads not-playing and correctly declines to pause — leaving nobody
        // owning the resume unless the obligation is carried forward.
        let client = FakeMediaPlaybackClient(playbackState: .playing)
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)
        controller.waitForIdle()
        #expect(client.playbackState == .notPlaying)

        // Hold the resume's query open so its toggle is never sent.
        client.completesImmediately = false
        controller.restoreDictationMediaPause()
        #expect(waitUntil { client.pendingQueryCount == 1 })

        // A new dictation starts inside that window.
        controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)
        client.completesImmediately = true
        while client.pendingQueryCount > 0 {
            client.completeNext(with: .notPlaying)
        }
        controller.waitForIdle()

        // Correctly declines to pause media that is already paused.
        #expect(client.playbackState == .notPlaying)

        // The outstanding resume must still be honoured on release.
        controller.restoreDictationMediaPause()
        controller.waitForIdle()
        #expect(client.playbackState == .playing)
    }

    @Test("begin does not block while playback state is pending")
    func beginDoesNotBlockWhilePlaybackStatePending() {
        let client = FakeMediaPlaybackClient(playbackState: .playing, completesImmediately: false)
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)

        // The call returns without waiting on the query, so the query is still
        // outstanding and nothing has been toggled.
        #expect(waitUntil { client.pendingQueryCount == 1 })
        #expect(client.toggles.isEmpty)

        // Let the verification pass resolve normally once the query answers.
        client.completesImmediately = true
        client.completeNext(with: .playing)
        controller.waitForIdle()

        #expect(client.toggles == [.pause])
    }

    @Test("release before the playback query completes sends no toggle")
    func releaseBeforeQueryCompletesSendsNoToggle() {
        let client = FakeMediaPlaybackClient(playbackState: .playing, completesImmediately: false)
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)
        #expect(waitUntil { client.pendingQueryCount == 1 })
        controller.restoreDictationMediaPause()

        client.completeNext(with: .playing)
        controller.waitForIdle()

        #expect(client.toggles.isEmpty)
        #expect(client.playbackState == .playing)
    }

    /// Polls `condition` until it holds or the timeout elapses. Used where the
    /// assertion is about work still being outstanding, which `waitForIdle`
    /// cannot express.
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(1_000)
        }
        return condition()
    }

    @Test("duplicate begin only pauses once")
    func duplicateBeginOnlyPausesOnce() {
        let client = FakeMediaPlaybackClient(playbackState: .playing)
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)
        controller.beginDictationMediaPause(enabled: true, routeKind: .speakerLike)
        controller.waitForIdle()

        #expect(client.toggles == [.pause])
    }

    @Test("headphone output still pauses")
    func headphoneOutputStillPauses() {
        // Ducking is route dependent because it exists to stop speaker bleed
        // into the microphone. Pausing is not: a user dictating over their own
        // music wants it paused on headphones too.
        let client = FakeMediaPlaybackClient(playbackState: .playing)
        let controller = makeController(client: client)

        controller.beginDictationMediaPause(enabled: true, routeKind: .headphoneLike)
        controller.waitForIdle()
        #expect(client.toggles == [.pause])

        controller.restoreDictationMediaPause()
        controller.waitForIdle()
        #expect(client.toggles == [.pause, .play])
    }

    private func makeController(client: FakeMediaPlaybackClient) -> MediaPlaybackController {
        MediaPlaybackController(
            client: client,
            queue: DispatchQueue(label: "test.media-playback"),
            policy: MediaPlaybackController.VerificationPolicy(
                maxToggleAttempts: 2,
                pollsPerAttempt: 3,
                pollInterval: .milliseconds(0)
            )
        )
    }
}

/// Models a real player: a toggle flips playback state, unless the event is
/// dropped in flight.
private final class FakeMediaPlaybackClient: MediaPlaybackClient, @unchecked Sendable {
    private let lock = NSLock()
    private var storedState: MediaPlaybackState
    private var storedToggles: [MediaPlaybackCommand] = []
    private var storedDrops = 0
    private var storedCompletesImmediately: Bool
    private var pendingCompletions: [(MediaPlaybackState) -> Void] = []

    init(playbackState: MediaPlaybackState, completesImmediately: Bool = true) {
        self.storedState = playbackState
        self.storedCompletesImmediately = completesImmediately
    }

    var playbackState: MediaPlaybackState {
        get { lock.withLock { storedState } }
        set { lock.withLock { storedState = newValue } }
    }

    var toggles: [MediaPlaybackCommand] {
        lock.withLock { storedToggles }
    }

    /// Number of subsequent toggles that will be recorded but not take effect.
    var togglesToDrop: Int {
        get { lock.withLock { storedDrops } }
        set { lock.withLock { storedDrops = newValue } }
    }

    var completesImmediately: Bool {
        get { lock.withLock { storedCompletesImmediately } }
        set { lock.withLock { storedCompletesImmediately = newValue } }
    }

    var pendingQueryCount: Int {
        lock.withLock { pendingCompletions.count }
    }

    func nowPlayingPlaybackState(completion: @escaping (MediaPlaybackState) -> Void) {
        lock.lock()
        guard storedCompletesImmediately else {
            pendingCompletions.append(completion)
            lock.unlock()
            return
        }
        let state = storedState
        lock.unlock()
        // Called outside the lock: the controller reenters the client from its
        // completion handler.
        completion(state)
    }

    func sendPlayPauseToggle(intent: MediaPlaybackCommand) {
        lock.withLock {
            storedToggles.append(intent)
            guard storedDrops == 0 else {
                storedDrops -= 1
                return
            }
            switch storedState {
            case .playing: storedState = .notPlaying
            case .notPlaying: storedState = .playing
            case .unknown: break
            }
        }
    }

    func completeNext(with playbackState: MediaPlaybackState) {
        lock.lock()
        let completion = pendingCompletions.removeFirst()
        lock.unlock()
        completion(playbackState)
    }
}
