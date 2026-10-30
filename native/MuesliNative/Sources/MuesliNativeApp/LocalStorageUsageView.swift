import SwiftUI
import MuesliCore

struct LocalStorageUsageView: View {
    @State private var usage: LocalStorageUsage?
    @State private var refreshID = UUID()
    @State private var isScanning = false
    @State private var showModels = false

    private let categories: [(LocalStorageUsage.Category, String, String, Color)] = [
        (.models, "Downloaded models", "cpu", .blue),
        (.meetingAudio, "Meeting audio", "waveform", .teal),
        (.meetingVideo, "Meeting video", "video", .purple),
        (.database, "Notes, transcripts & app database", "externaldrive", .orange),
        (.waveformCache, "Audio waveform cache", "waveform.path", .pink),
        (.other, "Other app data", "folder", .gray)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(usage.map { formatted($0.totalBytes) } ?? "Calculating…")
                        .font(MuesliTheme.font(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("muesli data and downloaded models").font(MuesliTheme.font(.caption)).foregroundStyle(.secondary)
                }
                Spacer()
                if isScanning { ProgressView().controlSize(.small) }
                Button { refreshID = UUID() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(isScanning).help("Refresh storage usage")
                    .accessibilityLabel("Refresh storage usage")
            }
            if let usage {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        ForEach(categories, id: \.0) { category, _, _, color in
                            Rectangle().fill(color).frame(width: geometry.size.width * Double(usage.bytes[category, default: 0]) / Double(max(1, usage.totalBytes)))
                        }
                    }
                }
                .frame(height: 8).background(.quaternary).clipShape(Capsule())
                .accessibilityHidden(true)

                ForEach(categories, id: \.0) { category, title, icon, color in
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: icon).foregroundStyle(color).frame(width: 20)
                            if category == .models && !usage.models.isEmpty {
                                Button { showModels.toggle() } label: {
                                    HStack(spacing: 6) {
                                        Text(title)
                                        Image(systemName: showModels ? "chevron.down" : "chevron.right").font(.caption2)
                                    }
                                }.buttonStyle(.plain)
                                .accessibilityValue(showModels ? "Expanded" : "Collapsed")
                            } else { Text(title) }
                            Spacer()
                            Text(formatted(usage.bytes[category, default: 0])).monospacedDigit().foregroundStyle(.secondary)
                        }
                        if category == .models && showModels {
                            ForEach(usage.models) { model in
                                HStack {
                                    Text(model.name).lineLimit(1).help(model.name)
                                    Spacer()
                                    Text(formatted(model.bytes)).monospacedDigit()
                                }.font(MuesliTheme.font(.caption)).foregroundStyle(.secondary).padding(.leading, 30)
                            }
                        }
                    }
                }
                Divider()
                HStack {
                    Text("Includes shared model caches")
                        .help("Allocated file sizes in muesli’s app data and known model folders. Model caches may also be used by other muesli builds or apps. The database includes dictation history. APFS sharing and compression can affect physical disk usage. App binaries, temporary recordings and system-managed caches are excluded.")
                    Spacer()
                    if let free = usage.freeBytes { Text("\(formatted(free)) available") }
                }.font(MuesliTheme.font(.caption)).foregroundStyle(.secondary)
                if usage.unavailableLocations > 0 {
                    Text("Some files could not be measured. Totals may be incomplete.").font(MuesliTheme.font(.caption)).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: refreshID) {
            isScanning = true
            let support = AppIdentity.supportDirectoryURL
            let home = FileManager.default.homeDirectoryForCurrentUser
            let roots = [support.appendingPathComponent("Models"), home.appendingPathComponent(".cache/muesli/models"),
                         ManagedASRModelPlans.fluidAudioModelsRoot(),
                         home.appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")]
            let scan = Task.detached(priority: .utility) { LocalStorageUsage.scan(support: support, modelRoots: roots) }
            let snapshot = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
            guard !Task.isCancelled else { return }
            usage = snapshot
            isScanning = false
        }
    }

    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
