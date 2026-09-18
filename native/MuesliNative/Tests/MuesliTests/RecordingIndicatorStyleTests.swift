import Foundation
import Testing
import SwiftUI
import AppKit
@testable import MuesliNativeApp

@Suite("Recording indicator style settings")
struct RecordingIndicatorStyleTests {
    @MainActor
    @Test("Style tiles render at Retina resolution with the Muesli mark")
    func renderTiles() throws {
        let content = RecordingIndicatorStylePicker(selection: .classic, onSelect: { _ in })
            .padding(20)
            .frame(width: 900)
            .background(Color(white: 0.09))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size.width == 900)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        #expect(bitmap.pixelsWide == 1800)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("muesli-indicator-settings-preview.png"))
    }

    @Test("Legacy style and position combinations preserve their selection")
    func legacyMapping() {
        var config = AppConfig()
        #expect(config.recordingIndicatorStyle == .classic)
        config.indicatorHoverStyle = .shortcutPill
        #expect(config.recordingIndicatorStyle == .minimal)
        config.indicatorAnchor = .notch
        #expect(config.recordingIndicatorStyle == .notch)
    }

    @Test("Switching through Notch preserves position and idle preferences across reload")
    func roundTrip() throws {
        var config = AppConfig()
        config.indicatorAnchor = .bottomLeading
        config.showFloatingIndicator = false
        config.showHotkeyOnFloatingIndicator = false
        config.selectRecordingIndicatorStyle(.notch)
        config.selectRecordingIndicatorStyle(.notch)
        var decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        decoded.selectRecordingIndicatorStyle(.minimal)
        #expect(decoded.indicatorAnchor == .bottomLeading)
        #expect(decoded.indicatorHoverStyle == .shortcutPill)
        #expect(!decoded.showFloatingIndicator)
        #expect(!decoded.showHotkeyOnFloatingIndicator)
    }

    @Test("Legacy notch without a saved position returns to top center")
    func legacyNotch() {
        var config = AppConfig()
        config.indicatorAnchor = .notch
        config.selectRecordingIndicatorStyle(.classic)
        #expect(config.indicatorAnchor == .topCenter)
        #expect(config.recordingIndicatorStyle == .classic)
    }
}
