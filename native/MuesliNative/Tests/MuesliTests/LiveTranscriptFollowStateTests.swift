import Testing
@testable import MuesliNativeApp

@Suite("Live transcript follow state")
struct LiveTranscriptFollowStateTests {
    @Test("a panel that has just rendered follows new captions")
    func followsAtFirstRender() {
        #expect(LiveTranscriptFollowState().shouldFollowNewContent)
    }

    @Test("a marker inside the visible area follows")
    func markerInsideViewportFollows() {
        var state = LiveTranscriptFollowState()
        state.noteBottomMarker(markerMinY: 380, viewportHeight: 400)
        #expect(state.shouldFollowNewContent)
    }

    @Test("a small scroll up leaves the marker loaded below the screen and stops following")
    func loadedButOffscreenMarkerStopsFollowing() {
        var state = LiveTranscriptFollowState()
        state.noteBottomMarker(markerMinY: 380, viewportHeight: 400)
        state.noteBottomMarker(markerMinY: 460, viewportHeight: 400)
        #expect(!state.shouldFollowNewContent)
    }

    @Test("a marker that unloads after the reader scrolls away stops following")
    func unloadedMarkerStopsFollowing() {
        var state = LiveTranscriptFollowState()
        state.noteBottomMarker(markerMinY: 380, viewportHeight: 400)
        state.noteBottomMarker(markerMinY: .infinity, viewportHeight: 400)
        #expect(!state.shouldFollowNewContent)
    }

    @Test("a viewport measured before the first caption keeps following")
    func viewportBeforeFirstCaptionKeepsFollowing() {
        var state = LiveTranscriptFollowState()
        state.noteBottomMarker(markerMinY: .infinity, viewportHeight: 400)
        #expect(state.shouldFollowNewContent)
        state.noteBottomMarker(markerMinY: 380, viewportHeight: 400)
        #expect(state.shouldFollowNewContent)
    }

    @Test("returning to the bottom resumes following")
    func returningToTheBottomResumes() {
        var state = LiveTranscriptFollowState()
        state.noteBottomMarker(markerMinY: 900, viewportHeight: 400)
        state.noteBottomMarker(markerMinY: 400, viewportHeight: 400)
        #expect(state.shouldFollowNewContent)
    }

    @Test("an unmeasured viewport changes nothing")
    func unmeasuredViewportIsIgnored() {
        var state = LiveTranscriptFollowState()
        state.noteBottomMarker(markerMinY: 900, viewportHeight: 0)
        #expect(state.shouldFollowNewContent)
    }

    @Test("a growing tail scrolls a follower, a cleared or whitespace-only tail does not")
    func tailChangeDecidesWhetherToScroll() {
        #expect(LiveTranscriptFollowState.tailChanged(from: "", to: "hello"))
        #expect(LiveTranscriptFollowState.tailChanged(from: "hello", to: "hello there"))
        #expect(!LiveTranscriptFollowState.tailChanged(from: "hello", to: " hello "))
        #expect(!LiveTranscriptFollowState.tailChanged(from: "hello", to: ""))
        #expect(!LiveTranscriptFollowState.tailChanged(from: "", to: "  "))
    }
}
