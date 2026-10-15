import AppKit
import SwiftUI
import Testing
@testable import MuesliNativeApp

@Suite("Meeting title layout")
@MainActor
struct MeetingTitleLayoutTests {
    private func width(of title: String, proposed: CGFloat) -> CGFloat {
        let column = VStack(alignment: .leading, spacing: 0) {
            MarqueeTitleTextField(text: .constant(title), onSubmit: {}, onTextChange: {})
            Text("below")
        }
        return NSHostingController(rootView: column)
            .sizeThatFits(in: CGSize(width: proposed, height: 400)).width
    }

    @Test("a title wider than the pane does not widen what contains it")
    func longTitleStaysInsideThePane() {
        let title = "Advanced Estate Planning Discussion with ASLG with Emma Osborne"
        #expect(width(of: title, proposed: 500) <= 500)
    }

    @Test("a short title takes no more room than a long one")
    func shortAndLongTitlesAgree() {
        #expect(width(of: "Standup", proposed: 500) == width(of: String(repeating: "Long title ", count: 12), proposed: 500))
    }
}
