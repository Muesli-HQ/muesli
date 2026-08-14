import AppKit
import MuesliCore
import SwiftUI
import UniformTypeIdentifiers

struct InsightsShareSheet: View {
    let snapshot: InsightsSnapshot
    let rangeLabel: String

    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var confirmation: String?
    @State private var saveErrorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Share your activity")
                        .font(.system(size: 20, weight: .semibold))
                        .tracking(-0.4)
                    Text("A private snapshot with no transcripts or account details")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(1200 / 630, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
                        .shadow(color: .black.opacity(0.22), radius: 24, y: 12)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.quaternary)
                        .aspectRatio(1200 / 630, contentMode: .fit)
                        .overlay { ProgressView().controlSize(.small) }
                }
            }
            .accessibilityLabel("Preview of your Muesli activity image")

            if let saveErrorMessage {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("The image couldn’t be saved")
                            .font(.system(size: 12, weight: .semibold))
                        Text(saveErrorMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button {
                        self.saveErrorMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss save error")
                }
                .padding(10)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.red.opacity(0.18)))
            }

            HStack(spacing: 10) {
                Button {
                    copyImage()
                } label: {
                    Label("Copy Image", systemImage: "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button {
                    saveImage()
                } label: {
                    Label("Save PNG", systemImage: "arrow.down.to.line")
                }

                Button {
                    shareImage()
                } label: {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                if let confirmation {
                    Label(confirmation, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .disabled(image == nil)
        }
        .padding(24)
        .frame(minWidth: 760, idealWidth: 880, minHeight: 530)
        .background(.regularMaterial)
        .task {
            image = InsightsShareRenderer.render(snapshot: snapshot, rangeLabel: rangeLabel)
        }
    }

    private func copyImage() {
        guard let image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        showConfirmation("Copied")
    }

    private func saveImage() {
        guard let image, let png = InsightsShareRenderer.pngData(for: image) else { return }
        saveErrorMessage = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Muesli activity – \(rangeLabel).png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let result = await Task.detached(priority: .utility) {
                    InsightsShareFileWriter.write(png, to: url)
                }.value
                switch result {
                case .saved:
                    saveErrorMessage = nil
                    showConfirmation("Saved")
                case .failed(let message):
                    saveErrorMessage = message
                }
            }
        }
    }

    private func shareImage() {
        guard let image else { return }
        InsightsNativeSharePicker.show(image: image)
    }

    private func showConfirmation(_ message: String) {
        withAnimation(.easeOut(duration: 0.16)) { confirmation = message }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard confirmation == message else { return }
            withAnimation(.easeOut(duration: 0.16)) { confirmation = nil }
        }
    }
}

enum InsightsShareSaveResult: Equatable, Sendable {
    case saved
    case failed(String)
}

enum InsightsShareFileWriter {
    static func write(_ png: Data, to url: URL) -> InsightsShareSaveResult {
        do {
            try png.write(to: url, options: .atomic)
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

@MainActor
enum InsightsShareRenderer {
    static let size = CGSize(width: 1200, height: 630)

    static func render(snapshot: InsightsSnapshot, rangeLabel: String) -> NSImage? {
        AppFonts.registerForRenderingIfNeeded()
        let renderer = ImageRenderer(
            content: InsightsShareCard(snapshot: snapshot, rangeLabel: rangeLabel, showsNumbers: true)
                .frame(width: size.width, height: size.height)
        )
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.nsImage
    }

    static func renderTemplate() -> NSImage? {
        AppFonts.registerForRenderingIfNeeded()
        let emptyTotals = InsightsTotals(dictationWords: 0, dictationSessions: 0, meetingWords: 0, meetings: 0, averageWPM: 0)
        let snapshot = InsightsSnapshot(
            range: .twelveMonths,
            generatedAt: Date(),
            lifetime: emptyTotals,
            selected: emptyTotals,
            dailyActivity: [],
            currentStreakDays: 0,
            longestStreakDays: 0,
            activeDaysInRange: 0,
            dictationWords: [],
            meetingWords: []
        )
        let renderer = ImageRenderer(
            content: InsightsShareCard(snapshot: snapshot, rangeLabel: "YOUR RANGE", showsNumbers: false)
                .frame(width: size.width, height: size.height)
        )
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.nsImage
    }

    static func pngData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff) else { return nil }
        return representation.representation(using: .png, properties: [.compressionFactor: 0.82])
    }
}

private struct InsightsShareCard: View {
    let snapshot: InsightsSnapshot
    let rangeLabel: String
    let showsNumbers: Bool

    private let pale = Color(red: 0.91, green: 0.95, blue: 0.98)
    private let muted = Color(red: 0.61, green: 0.68, blue: 0.74)
    private let cyan = Color(red: 0.20, green: 0.78, blue: 0.91)

    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.071, blue: 0.090)

            if let background = InsightsBrandAssets.shareBackground {
                Image(nsImage: background)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 1200, height: 630)
                    .clipped()
            }

            LinearGradient(
                colors: [
                    Color(red: 0.035, green: 0.050, blue: 0.068).opacity(0.08),
                    Color(red: 0.045, green: 0.062, blue: 0.080).opacity(0.12),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Text(rangeLabel.uppercased())
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(1.9)
                        .foregroundStyle(pale.opacity(0.82))
                    Spacer()
                    MuesliShareMark(color: pale)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color(red: 0.035, green: 0.050, blue: 0.068).opacity(0.44))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12)))
                }

                Spacer(minLength: 34)

                Text(showsNumbers ? snapshot.selected.totalWords.formatted() : "—")
                    .font(.system(size: 108, weight: .bold, design: .rounded))
                    .tracking(-5)
                    .monospacedDigit()
                    .foregroundStyle(pale)
                Text("WORDS CAPTURED")
                    .font(.system(size: 18, weight: .bold))
                    .tracking(2.8)
                    .foregroundStyle(muted)

                Spacer(minLength: 36)

                HStack(spacing: 0) {
                    shareDatum(value: showsNumbers ? snapshot.selected.meetings.formatted() : "—", label: "MEETINGS")
                    shareDivider
                    shareDatum(value: showsNumbers ? "\(Int(snapshot.selected.averageWPM.rounded()))" : "—", label: "AVERAGE WPM")
                    shareDivider
                    shareDatum(value: showsNumbers ? dayCount(snapshot.currentStreakDays) : "—", label: "CURRENT STREAK")
                    shareDivider
                    shareDatum(value: showsNumbers ? dayCount(snapshot.longestStreakDays) : "—", label: "LONGEST STREAK")
                }
                .padding(.vertical, 24)
                .background(Color(red: 0.035, green: 0.050, blue: 0.068).opacity(0.48))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.16)))

                Spacer(minLength: 30)

                HStack {
                    Text("Private by design. Made on this Mac.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(pale.opacity(0.88))
                        .shadow(color: Color.black.opacity(0.48), radius: 3, y: 1)
                    Spacer()
                    Text("muesli.works")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(cyan)
                        .shadow(color: Color.black.opacity(0.48), radius: 3, y: 1)
                }
            }
            .padding(54)
        }
    }

    private func shareDatum(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .tracking(-0.8)
                .monospacedDigit()
                .foregroundStyle(pale)
            Text(label)
                .font(.system(size: 12, weight: .bold))
                .tracking(1.7)
                .foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
    }

    private var shareDivider: some View {
        Rectangle().fill(Color.white.opacity(0.11)).frame(width: 1, height: 58)
    }

    private func dayCount(_ value: Int) -> String {
        "\(value) \(value == 1 ? "DAY" : "DAYS")"
    }
}

private struct MuesliShareMark: View {
    let color: Color

    var body: some View {
        HStack(spacing: 11) {
            if let icon = InsightsBrandAssets.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Text("muesli")
                .font(Font(AppFonts.bold(30)))
                .tracking(-1.1)
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Muesli")
    }
}

enum InsightsBrandAssets {
    static let shareBackground = image(
        bundledName: "insights-share-background",
        extension: "png",
        repositoryPath: "assets/insights-share-background.png"
    )
    static let appIcon = image(
        bundledName: "muesli_app_icon",
        extension: "png",
        repositoryPath: "assets/muesli_app_icon.png"
    )

    private static func image(bundledName: String, extension fileExtension: String, repositoryPath: String) -> NSImage? {
        if let bundledURL = Bundle.main.url(forResource: bundledName, withExtension: fileExtension),
           let image = NSImage(contentsOf: bundledURL) {
            return image
        }
        if let repositoryRoot = ProcessInfo.processInfo.environment["MUESLI_REPO_ROOT"],
           let image = NSImage(contentsOf: URL(fileURLWithPath: repositoryRoot, isDirectory: true).appendingPathComponent(repositoryPath)) {
            return image
        }
        let workingDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        if let image = NSImage(contentsOf: workingDirectoryURL.appendingPathComponent(repositoryPath)) {
            return image
        }
        guard let runtime = try? RuntimePaths.resolve() else { return nil }
        return NSImage(contentsOf: runtime.repoRoot.appendingPathComponent(repositoryPath))
    }
}

@MainActor
private enum InsightsNativeSharePicker {
    private static var picker: NSSharingServicePicker?

    static func show(image: NSImage) {
        guard let sourceView = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [image])
        self.picker = picker
        let anchor = NSRect(x: sourceView.bounds.midX, y: sourceView.bounds.midY, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: sourceView, preferredEdge: .minY)
    }
}
