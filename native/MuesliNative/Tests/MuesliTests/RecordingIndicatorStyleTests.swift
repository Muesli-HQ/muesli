import Foundation
import Testing
import SwiftUI
import AppKit
import Vision
import MuesliCore
@testable import MuesliNativeApp

@Suite("Recording indicator style settings")
struct RecordingIndicatorStyleTests {
    @MainActor
    @Test("Compact computer-use expansion renders bounded responses", arguments: [0, 3])
    func compactToolResponses(count: Int) throws {
        let results = ["Opened app", "Read page text", "Inspect page elements — needs approval"]
            .prefix(count).compactMap { NotchToolResult(ComputerUseTraceEvent(kind: "tool_result", title: "Tool result", body: "Full tool response", compactSummary: $0, status: "executed")) }
        let geometry = NotchIndicatorGeometry(cutout: CGRect(x: 200, y: 900, width: 180, height: 32), wingWidth: 110)
        let frame = geometry.instructionFrame(in: CGRect(x: 0, y: 0, width: 1200, height: 900), resultCount: count)
        let hosting = NSHostingView(rootView: NotchLiveInstructionView(
            instruction: "Can you open Twitter on Google Chrome?", status: "Working…",
            appName: "Instruction", appIcon: nil, accent: .blue, toolResults: results,
            onCollapse: {}, onCancel: {}).frame(width: frame.width, height: frame.height))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: frame.width, height: frame.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        #expect(bitmap.pixelsHigh >= Int(frame.height))
        // Read the rendered pixels so blank or clipped instruction/response/control text fails.
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        let cgImage = try #require(bitmap.cgImage)
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        let recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        func words(_ text: String) -> String {
            text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
        }
        let expected = ["Can you open Twitter on Google Chrome?", "Cancel"] + results.map(\.message)
        for text in expected {
            #expect(words(recognized).contains(words(text)), "Missing or clipped content: \(text); rendered: \(recognized)")
        }
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("muesli-compact-tool-responses-\(count).png"))
    }

    @MainActor
    @Test("Live instruction panel renders long text and review controls", arguments: [false, true])
    func liveInstructionPanel(review: Bool) throws {
        let renderer = ImageRenderer(content: NotchLiveInstructionView(
            instruction: String(repeating: "Make this paragraph more concise. ", count: 12),
            status: review ? "This action requires confirmation." : "Rewriting selection",
            appName: "TextEdit", appIcon: nil, accent: .blue, requiresReview: review,
            onCollapse: {}, onCancel: {}).frame(width: 440, height: review ? 180 : 115))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        #expect(bitmap.pixelsWide == 880)
        #expect(bitmap.pixelsHigh == (review ? 360 : 230))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("muesli-live-instruction-\(review).png"))
    }

    @Test("Indicator palette respects custom accents and keeps neutral visible")
    func palette() {
        let color = RecordingIndicatorPalette.accent(hex: "#336699")
        #expect(abs(color.redComponent - 0.2) < 0.001)
        #expect(abs(color.greenComponent - 0.4) < 0.001)
        #expect(abs(color.blueComponent - 0.6) < 0.001)
        #expect(RecordingIndicatorPalette.accent(hex: "1e1e2e") == RecordingIndicatorPalette.accent(hex: "invalid"))
    }

    @MainActor
    @Test("Expanded instruction previews render in both modes", arguments: ["Quill", "Computer use"])
    func expandedPreview(mode: String) throws {
        let renderer = ImageRenderer(content: NotchInstructionPreview(accent: .purple, mode: mode, phase: "Needs approval")
            .environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("muesli-expanded-\(mode).png"))
        #expect(bitmap.pixelsWide == 1400)
    }

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
