import Testing
@testable import MuesliNativeApp

@Suite("Live transcript follow state")
struct LiveTranscriptFollowStateTests {
    @Test("a panel that has just rendered follows new captions")
    func followsAtFirstRender() {
        #expect(LiveTranscriptFollowState().shouldFollowNewContent)
    }

    @Test("scrolling up stops the panel from pulling the reader down")
    func scrollingUpStopsFollowing() {
        var state = LiveTranscriptFollowState()
        state.noteBottomMarker(visible: true)
        state.noteBottomMarker(visible: false)
        #expect(!state.shouldFollowNewContent)
    }

    @Test("returning to the bottom resumes following")
    func returningToTheBottomResumes() {
        var state = LiveTranscriptFollowState()
        state.noteBottomMarker(visible: false)
        state.noteBottomMarker(visible: true)
        #expect(state.shouldFollowNewContent)
    }
}
