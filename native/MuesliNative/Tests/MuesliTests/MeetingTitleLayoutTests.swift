import AppKit
import SwiftUI
import Testing
@testable import MuesliNativeApp

@Suite("Meeting title layout")
@MainActor
struct MeetingTitleLayoutTests {
    private func width(of title: String, proposed: CGFloat, titleSize: CGFloat = 30) -> CGFloat {
        let column = VStack(alignment: .leading, spacing: 0) {
            MarqueeTitleTextField(text: .constant(title), titleSize: titleSize, onSubmit: {}, onTextChange: {})
            Text("below")
        }
        return NSHostingController(rootView: column)
            .sizeThatFits(in: CGSize(width: proposed, height: 400)).width
    }

    @Test("long titles fill the available width without widening standard or compact layouts",
          arguments: [CGFloat(260), 500, 900], [CGFloat(24), 30])
    func longTitleStaysInsideThePane(proposedWidth: CGFloat, titleSize: CGFloat) {
        let title = "Advanced Estate Planning Discussion with ASLG with Emma Osborne"
        #expect(abs(width(of: title, proposed: proposedWidth, titleSize: titleSize) - proposedWidth) < 0.5)
    }

    @Test("a short title takes no more room than a long one")
    func shortAndLongTitlesAgree() {
        #expect(width(of: "Standup", proposed: 500) == width(of: String(repeating: "Long title ", count: 12), proposed: 500))
    }

    @Test("the title row does not absorb extra height",
          arguments: [CGFloat(100), 400, 900], [CGFloat(24), 30])
    func titleHeightStaysBounded(proposedHeight: CGFloat, titleSize: CGFloat) {
        let row = MarqueeTitleTextField(
            text: .constant("A long meeting title"), titleSize: titleSize, onSubmit: {}, onTextChange: {}
        )
        let host = NSHostingController(rootView: row)
        let naturalHeight = host.sizeThatFits(in: CGSize(width: 500, height: 0)).height
        let size = host.sizeThatFits(in: CGSize(width: 500, height: proposedHeight))
        // Font metrics differ between the compact and standard titles (and SDKs).
        // The invariant is one readable line, independent of surplus parent height.
        let textHeight = NSHostingController(rootView: Text("A long meeting title")
            .font(MuesliTheme.font(size: titleSize, weight: .bold)).fixedSize())
            .sizeThatFits(in: CGSize(width: 500, height: proposedHeight)).height
        #expect(abs(size.height - naturalHeight) < 0.5)
        #expect(size.height >= textHeight)
        #expect(size.height <= textHeight + 16)
    }
}
