import AppKit
import CoreText
import Foundation
import MuesliCore

/// Process-local, offline typography shared by SwiftUI, AppKit and text measurement.
/// Swift's static initialization registers the resources exactly once, including in tests/CLI.
enum AppFonts {
    static let family = "Nunito Sans"
    private static let cache = NSCache<NSString, NSFont>()
    private static let registration: Void = {
        let names = ["Regular", "Medium", "SemiBold", "Bold", "ExtraBold", "Italic", "BoldItalic"]
        for name in names {
            guard let url = Bundle.module.url(forResource: "NunitoSans-\(name)", withExtension: "ttf", subdirectory: "Fonts") else {
                NSLog("Muesli: missing bundled font NunitoSans-%@", name)
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error), let error = error?.takeRetainedValue(),
               CFErrorGetCode(error) != CTFontManagerError.alreadyRegistered.rawValue {
                NSLog("Muesli: font registration failed: %@", String(describing: error))
            }
        }
        cache.countLimit = 128
    }()

    static func registerIfNeeded(runtime: RuntimePaths) { registerForRenderingIfNeeded() }
    static func registerForRenderingIfNeeded() { _ = registration }

    static func postScriptName(weight: NSFont.Weight = .regular, italic: Bool = false) -> String {
        if italic { return weight >= .semibold ? "NunitoSans-BoldItalic" : "NunitoSans-Italic" }
        let suffix: String
        switch weight {
        case ..<NSFont.Weight.medium: suffix = "Regular"
        case ..<NSFont.Weight.semibold: suffix = "Medium"
        case ..<NSFont.Weight.bold: suffix = "SemiBold"
        case ..<NSFont.Weight.heavy: suffix = "Bold"
        default: suffix = "ExtraBold"
        }
        return "NunitoSans-\(suffix)"
    }

    static func font(size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        registerForRenderingIfNeeded()
        let name = postScriptName(weight: weight, italic: italic)
        let key = "\(name):\(size)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let font = NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
        cache.setObject(font, forKey: key)
        return font
    }

    static func regular(_ size: CGFloat) -> NSFont { font(size: size) }
    static func medium(_ size: CGFloat) -> NSFont { font(size: size, weight: .medium) }
    static func semibold(_ size: CGFloat) -> NSFont { font(size: size, weight: .semibold) }
    static func bold(_ size: CGFloat) -> NSFont { font(size: size, weight: .bold) }
}
