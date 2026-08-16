import AppKit
import SwiftUI
import MuesliCore

@MainActor
private enum TargetApplicationIconResolver {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleIdentifier.isEmpty else {
            return nil
        }

        let key = bundleIdentifier as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let runningURL = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first?
            .bundleURL
        guard let applicationURL = runningURL
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}

struct TargetApplicationIconView: View {
    let appName: String
    let bundleIdentifier: String?
    var size: CGFloat = 20

    private var accessibilityText: String {
        "Dictated into \(appName)"
    }

    var body: some View {
        Group {
            if let icon = TargetApplicationIconResolver.icon(bundleIdentifier: bundleIdentifier) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.13)
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .help(accessibilityText)
    }
}

struct TargetApplicationFilterMenu: View {
    let applications: [DictationTargetApplication]
    let selection: DictationTargetApplication?
    let onSelect: (DictationTargetApplication?) -> Void

    var body: some View {
        Menu {
            Button {
                onSelect(nil)
            } label: {
                HStack {
                    Text("All apps")
                    if selection == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }

            if !applications.isEmpty {
                Divider()
                ForEach(applications) { application in
                    Button {
                        onSelect(application)
                    } label: {
                        HStack {
                            Text(application.name)
                            if selection?.id == application.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if let selection {
                    TargetApplicationIconView(
                        appName: selection.name,
                        bundleIdentifier: selection.bundleID,
                        size: 16
                    )
                    Text(selection.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                } else {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 11))
                    Text("Apps")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(selection == nil ? MuesliTheme.textTertiary : MuesliTheme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selection == nil ? Color.clear : MuesliTheme.accent.opacity(0.12))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(selection.map { "Showing dictations for \($0.name)" } ?? "Filter by destination app")
        .accessibilityLabel("Destination application filter")
        .accessibilityValue(selection?.name ?? "All apps")
    }
}
