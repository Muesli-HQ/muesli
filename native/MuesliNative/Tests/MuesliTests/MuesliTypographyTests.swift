import AppKit
import CoreText
import Testing
@testable import MuesliNativeApp

@MainActor
@Suite("Bundled Muesli typography")
struct MuesliTypographyTests {
    @Test func bundledWeightsResolveWithoutSystemFallback() {
        for weight: NSFont.Weight in [.regular, .medium, .semibold, .bold, .heavy] {
            let font = AppFonts.font(size: 14, weight: weight)
            #expect(font.fontName == AppFonts.postScriptName(weight: weight))
            #expect(font.familyName == AppFonts.family)
            #expect(font.pointSize == 14)
            let source = CTFontCopyAttribute(font as CTFont, kCTFontURLAttribute) as? URL
            #expect(source?.lastPathComponent == font.fontName + ".ttf")
            #expect(source?.path.contains(".bundle/") == true, "Must use the packaged face, not an installed font")
        }
    }

    @Test func markdownTraitsUseRealBundledFaces() {
        let regular = AppFonts.regular(16)
        let bold = NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask)
        let italic = NSFontManager.shared.convert(regular, toHaveTrait: .italicFontMask)
        let boldItalic = NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask)
        #expect(bold.fontName == "NunitoSans-Bold")
        #expect(italic.fontName == "NunitoSans-Italic")
        #expect(boldItalic.fontName == "NunitoSans-BoldItalic")
        #expect(NSFontManager.shared.convert(bold, toNotHaveTrait: .boldFontMask).fontName == regular.fontName)
    }

    @Test func defaultDigitsKeepCountersStable() {
        for weight: NSFont.Weight in [.regular, .medium, .semibold, .bold, .heavy] {
            let font = AppFonts.font(size: 20, weight: weight)
            let widths = (0...9).map { NSAttributedString(string: String($0), attributes: [.font: font]).size().width }
            #expect((widths.max() ?? 0) - (widths.min() ?? 0) < 0.01)
        }
    }

    @Test func multilingualTextRetainsSystemGlyphFallback() {
        for sample in ["Café — Muesli", "नमस्ते दुनिया", "வணக்கம்", "你好", "مرحبا", "Meeting 👋"] {
            let text = NSAttributedString(string: sample, attributes: [.font: AppFonts.regular(15)])
            let line = CTLineCreateWithAttributedString(text)
            #expect(CTLineGetTypographicBounds(line, nil, nil, nil) > 0)
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                #expect(!glyphs.contains(0), "Missing glyph in \(sample)")
            }
        }
    }
}
