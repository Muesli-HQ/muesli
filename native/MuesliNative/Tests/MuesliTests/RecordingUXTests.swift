import AppKit
import Testing
import SwiftUI
@testable import MuesliNativeApp

@Suite("Recording UX", .serialized)
struct RecordingUXTests {
    @Test("activation delay accepts intermediate keystrokes and validates only at commit")
    func activationDelayDraft() {
        var draft = ActivationDelayDraft(value: 250)
        for text in ["", "1", "10", "100"] {
            draft.text = text
            #expect(draft.text == text)
        }
        #expect((draft.commit(fallback: 250) == 100))
        draft.text = "0"
        #expect((draft.commit(fallback: 250) == 50))
        draft.text = "2500"
        #expect((draft.commit(fallback: 250) == 2000))
        for invalid in ["", "abc", "999999999999999999999999999999"] {
            draft.text = invalid
            #expect((draft.commit(fallback: 250) == 250))
            #expect(draft.text == "250")
        }
    }

    @Test("reset invalidates an edited delay even if saved value is unchanged or blur arrives late",
          arguments: [100, 250])
    func activationDelayReset(savedValue: Int) {
        var draft = ActivationDelayDraft(value: savedValue, resetRevision: 0)
        draft.text = "700"
        let result = draft.commit(fallback: 250, resetRevision: 1)
        #expect(result == 250)
        #expect(draft.text == "250")
        draft.text = "120"
        let editedAfterReset = draft.commit(fallback: 250, resetRevision: 1)
        #expect(editedAfterReset == 120)
    }

    @Test("scroll ticks within the same following region leave state unchanged")
    func transcriptFollowNoOp() {
        var state = LiveTranscriptFollowState()
        let atTop = state
        for top in [CGFloat(0), -5, -20] {
            let refresh = state.updateTop(top)
            #expect(!refresh)
            #expect(state == atTop)
        }
        _ = state.updateTop(-100)
        _ = state.receiveUpdate()
        let reading = state
        for top in [CGFloat(-110), -150, -80] {
            let refresh = state.updateTop(top)
            #expect(!refresh)
            #expect(state == reading)
        }
        let refresh = state.updateTop(0)
        #expect(refresh)
        #expect(state == atTop)
    }

    @Test("new captions and partials wait while reading history and resume at the top")
    func transcriptFollow() {
        var follow = LiveTranscriptFollowState()
        let result1 = follow.receiveUpdate()
        #expect(result1)
        let result2 = !follow.updateTop(-120)
        #expect(result2)
        let result3 = !follow.receiveUpdate()
        #expect(result3)
        let result4 = !follow.receiveUpdate()
        #expect(result4)
        #expect(follow.hasPendingUpdates)
        let result5 = !follow.updateTop(-80)
        #expect(result5)
        let result6 = follow.updateTop(0)
        #expect(result6)
        #expect(!follow.hasPendingUpdates)
        let result7 = follow.receiveUpdate()
        #expect(result7)
        _ = follow.updateTop(-200)
        _ = follow.receiveUpdate()
        follow.showLatest()
        #expect(follow.isFollowing)
        #expect(!follow.hasPendingUpdates)
    }

    @MainActor
    @Test("recording buttons keep readable single-line labels under narrow proposals",
          arguments: [CGFloat(20), 40, 100, 300], [false, true])
    func recordingButtonSize(width: CGFloat, paused: Bool) {
        let pause = NSHostingController(rootView: RecordingPauseButton(isPaused: paused, action: {}))
        let stop = NSHostingController(rootView: Button(action: {}) {
            RecordingControlLabel(title: "Stop", systemImage: "stop.fill")
        }.buttonStyle(.muesli(.recording)))
        func check<Content: View>(_ host: NSHostingController<Content>) {
            let natural = host.sizeThatFits(in: CGSize(width: 300, height: 400))
            let constrained = host.sizeThatFits(in: CGSize(width: width, height: 400))
            #expect(abs(constrained.width - natural.width) < 0.5)
            #expect(abs(constrained.height - natural.height) < 0.5)
            #expect(constrained.height <= 36)
            #expect(constrained.width > 50)
        }
        check(pause)
        check(stop)
    }

    @MainActor
    @Test("Live tab preserves the native viewport while updates wait", arguments: [360.0, 720.0])
    func liveTranscriptViewport(width: Double) async throws {
        let transcript = (0..<60).map { "[00:\($0)] You: Caption \($0) with enough text to wrap on a narrow window." }.joined(separator: "\n")
        let input = TranscriptTestInput(transcript: transcript)
        let host = NSHostingView(rootView: TranscriptTestView(input: input))
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: width, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func settle() async throws {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
        }
        func findScroll(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { findScroll($0) }.first
        }
        try await settle()
        let scroll = try #require(findScroll(host))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        let before = scroll.contentView.bounds.origin
        let heightBefore = try #require(scroll.documentView).frame.height
        #expect(before.y > 24)
        let expanded = transcript + "\n[01:01] Others: Newly arrived caption."
        input.transcript = expanded
        input.partial = "More speech arriving"
        try await settle()
        #expect(abs(scroll.contentView.bounds.origin.y - before.y) < 1)
        #expect(abs(try #require(scroll.documentView).frame.height - heightBefore) < 1)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        #expect(abs(scroll.contentView.bounds.origin.y) < 1)
    }

    @MainActor
    @Test("drag rebases transcript collapse but not unrelated panel movement", arguments: [false, true], [false, true])
    func expandedMeetingDrag(transcriptOnLeft: Bool, expanded: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigStore(supportDirectory: directory)
        var config = AppConfig()
        config.indicatorAnchor = transcriptOnLeft ? .midTrailing : .bottomLeading
        config.showMeetingTranscriptOnIndicatorHover = true
        store.save(config)
        var pointer = NSPoint(x: -10000, y: -10000)
        let indicator = FloatingIndicatorController(configStore: store, pointerLocation: { pointer })
        defer { indicator.close(); try? FileManager.default.removeItem(at: directory) }
        indicator.setMeetingRecording(true, config: config)
        let original = try #require(indicator.currentFrame)
        if expanded { indicator.setHovered(true) }
        let pill = try #require(NSApp.windows.flatMap { $0.contentView?.subviews ?? [] }
            .compactMap { $0 as? HoverIndicatorView }.first { $0.owner === indicator })
        let window = try #require(pill.window)
        #expect(expanded ? window.frame.width > original.width : window.frame.width == original.width)
        pointer = NSPoint(x: original.midX, y: original.midY)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type,
                location: window.convertPoint(fromScreen: pointer), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        pill.mouseDown(with: try event(.leftMouseDown))
        #expect(!window.isMovable)
        #expect(indicator.currentFrame == original)
        if !expanded {
            // Simulate a hover animation moving the panel between mouse-down
            // and the first drag event; that offset must not enter drag math.
            window.setFrameOrigin(NSPoint(x: window.frame.minX + 40, y: window.frame.minY + 20))
        }
        pointer.x += 12
        pointer.y += 9
        pill.mouseDragged(with: try event(.leftMouseDragged))
        let moved = try #require(indicator.currentFrame)
        #expect(abs(moved.minX - original.minX - 12) < 0.1)
        #expect(abs(moved.minY - original.minY - 9) < 0.1)
        #expect(window.frame.size == original.size)
        pointer.x += 7
        pill.mouseDragged(with: try event(.leftMouseDragged))
        #expect(abs(try #require(indicator.currentFrame).minX - original.minX - 19) < 0.1)
        pill.mouseUp(with: try event(.leftMouseUp))
        #expect(window.isMovable)
    }
}

@MainActor
private final class TranscriptTestInput: ObservableObject {
    @Published var transcript: String
    @Published var partial = ""
    init(transcript: String) { self.transcript = transcript }
}

private struct TranscriptTestView: View {
    @ObservedObject var input: TranscriptTestInput
    var body: some View {
        LiveTranscriptView(transcript: input.transcript, partialYou: input.partial)
    }
}
