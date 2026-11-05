import Foundation
import Observation
import SwiftUI

/// Visible feature introductions, not a list of every change in the release.
enum NewFeature: String, CaseIterable {
    case chat, timeTurner, granolaImport, cotypist, liveDictation, appFormatting

    static func sidebar(_ tab: DashboardTab) -> Self? {
        switch tab {
        case .meetingChat: .chat
        case .timeTurner: .timeTurner
        default: nil
        }
    }

    static func setting(_ id: String) -> Self? {
        if id == "buffered_live_dictation" { return .liveDictation }
        if id.hasPrefix("cotypist_") { return .cotypist }
        if id.hasPrefix("dictation_format_") { return .appFormatting }
        return nil
    }
}

/// Bundle-local discovery state, independent of the tour and user activity data.
/// Read once; views observe memory, and only the first interaction writes defaults.
@MainActor @Observable
final class NewFeatureDiscovery {
    static let shared = NewFeatureDiscovery()
    private let defaults: UserDefaults
    private let key: String
    private var discovered: Set<String>

    init(defaults: UserDefaults = .standard, release: String = "0.8.6") {
        self.defaults = defaults
        key = "featureDiscovery.\(release).seen"
        discovered = Set(defaults.stringArray(forKey: key) ?? [])
    }

    func isNew(_ feature: NewFeature) -> Bool { !discovered.contains(feature.rawValue) }

    func markUsed(_ feature: NewFeature) {
        guard discovered.insert(feature.rawValue).inserted else { return }
        defaults.set(discovered.sorted(), forKey: key)
    }
}

struct NewFeatureBadge: View {
    let feature: NewFeature

    var body: some View {
        if NewFeatureDiscovery.shared.isNew(feature) {
            Text("New")
                .font(MuesliTheme.font(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(MuesliTheme.accentPalette.badgeFill, in: Capsule())
                .fixedSize()
                .allowsHitTesting(false)
                .accessibilityLabel("New feature")
        }
    }
}
