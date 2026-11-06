import CoreGraphics
import Testing
@testable import MuesliNativeApp

@Suite("Cotypist setup guide placement")
struct CotypistSetupGuideLayoutTests {
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1080)
    private let size = CotypistSetupGuideLayout.size

    @Test("sits to the right of System Settings when there's room")
    func right() {
        let settings = CGRect(x: 300, y: 200, width: 900, height: 700)
        let frame = CotypistSetupGuideLayout.frame(besides: settings, on: screen)
        #expect(frame.minX == settings.maxX + CotypistSetupGuideLayout.gap)
        #expect(frame.size == size)
        #expect(!frame.intersects(settings))
    }

    @Test("moves to the left when the window hugs the right edge")
    func left() {
        let settings = CGRect(x: 780, y: 200, width: 900, height: 700)
        let frame = CotypistSetupGuideLayout.frame(besides: settings, on: screen)
        #expect(frame.maxX == settings.minX - CotypistSetupGuideLayout.gap)
        #expect(!frame.intersects(settings))
    }

    @Test("falls back inside the window's bottom-left corner when it fills the screen")
    func inside() {
        let settings = CGRect(x: 0, y: 0, width: 1728, height: 1080)
        let frame = CotypistSetupGuideLayout.frame(besides: settings, on: screen)
        #expect(frame.minX == 16 && frame.minY == 16)
        #expect(screen.contains(frame))
    }
}
