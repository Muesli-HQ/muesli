import AppKit
import SwiftUI

/// Colour of the label that marks builds other than the release app (see
/// `AppIdentity.buildBadge`). scripts/badge_app_icon.swift uses the same
/// orange for the pill it bakes into those builds' icons.
enum BuildBadge {
    static let nsColor = NSColor.systemOrange
    static var color: Color { Color(nsColor: nsColor) }
}
