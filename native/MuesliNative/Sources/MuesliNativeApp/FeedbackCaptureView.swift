import SwiftUI
import AVKit
import MuesliCore

struct FeedbackCaptureView: View {
    let controller: FeedbackCaptureController
    @State var selectedID: String?
    @State private var manifest: FeedbackCaptureManifest?
    @State private var player: AVPlayer?
    @State private var mode = "Screen"
    @State private var videoURL: URL?
    @State private var audioURL: URL?
    @State private var message: String?
    @State private var loading = true
    @State private var confirmDelete = false
    @State private var activeWriter = true
    @State private var bundleURL: URL?
    private var selected: FeedbackCaptureRecord? { selectedID == nil ? controller.records.first : controller.records.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if loading { ProgressView("Loading captures…") }
            if let selected {
                Picker("Capture", selection: Binding(get: { selected.id }, set: { selectedID = $0 })) {
                    ForEach(controller.records) { record in
                        Text("\(record.title) · \(Date(timeIntervalSince1970: record.createdAt).formatted())").tag(record.id)
                    }
                }
                HStack {
                    Text(selected.title).font(.headline)
                    Text(Date(timeIntervalSince1970: selected.createdAt).formatted()).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%d:%02d", selected.durationMs / 60_000, (selected.durationMs / 1000) % 60)).monospacedDigit()
                }
                if videoURL != nil && audioURL != nil {
                    Picker("Media", selection: $mode) {
                        Text("Video").tag("Screen")
                        Text("Audio").tag("Audio")
                    }
                    .pickerStyle(.segmented).frame(width: 180)
                }
                if videoURL != nil && (mode == "Screen" || audioURL == nil) {
                    if let player { MeetingVideoPlayerView(player: player).frame(minHeight: 220, maxHeight: .infinity) }
                } else if let audioURL {
                    MeetingRecordingPlayerView(recordingPath: audioURL.path).id(audioURL)
                } else {
                    ContentUnavailableView("Media unavailable", systemImage: "video.slash", description: Text("The saved media may be missing or still recording."))
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Narration").font(.headline)
                        if manifest?.transcript?.estimated == true, manifest?.transcript?.missing == nil {
                            Text("Estimated timing").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let transcript = manifest?.transcript {
                        if let missing = transcript.missing { Text("No transcript: \(missing.reason)").foregroundStyle(.secondary) }
                        else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(transcript.segments.enumerated()), id: \.offset) { _, segment in
                                        Text(String(format: "%d:%02d  %@", segment.t0 / 60_000,
                                            (segment.t0 / 1000) % 60, segment.text))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }.textSelection(.enabled)
                            }.frame(maxHeight: 100)
                        }
                    } else {
                        Text(selected.state == .processing ? "Transcribing narration…" : "No transcript saved")
                            .foregroundStyle(.secondary)
                    }
                }
                Text(manifest?.state.rawValue.capitalized ?? selected.state.rawValue.capitalized).font(.headline)
                if manifest?.audio == nil, manifest?.video != nil { Text("Video only · narration unavailable").foregroundStyle(.secondary) }
                if manifest?.video == nil, manifest?.audio != nil { Text("Audio only · video unavailable").foregroundStyle(.secondary) }
                ForEach(Array((manifest?.failures ?? []).enumerated()), id: \.offset) { _, failure in
                    Text("\(failure.stage): \(failure.message)").font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Show in Finder") {
                        if let url = bundleURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    Spacer()
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                        .disabled(loading || activeWriter)
                }
            } else if !loading {
                ContentUnavailableView("No Scrawl captures", systemImage: "video", description: Text("Enable Scrawl in General settings, then release your shortcut to record."))
            }
            if let state = controller.state, controller.hasAttempt { Text(state.title).foregroundStyle(.secondary) }
            if let message { Text(message).foregroundStyle(.orange) }
            if let error = controller.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .padding(24)
        .task(id: "\(selected?.id ?? "none")-\(selected?.state.rawValue ?? "none")-\(controller.hasAttempt)") {
            loading = true; player?.pause(); player = nil; manifest = nil; message = nil; bundleURL = nil
            videoURL = nil; audioURL = nil; mode = "Screen"
            defer { if !Task.isCancelled { loading = false } }
            guard let id = selected?.id, let store = controller.store else { return }
            let isActive = await Task.detached { store.isActive(id: id) }.value
            guard !Task.isCancelled else { return }
            activeWriter = isActive
            do {
                let loaded = try await Task.detached { () throws -> (FeedbackCaptureManifest, URL?, URL?, URL) in
                    let manifest = try store.manifest(id: id)
                    func existingURL(_ path: String?) throws -> URL? {
                        guard let path else { return nil }
                        let url = try store.mediaURL(id: id, path: path)
                        return FileManager.default.fileExists(atPath: url.path) ? url : nil
                    }
                    return (manifest, try existingURL(manifest.video), try existingURL(manifest.audio),
                        try store.bundleURL(id: id))
                }.value
                guard !Task.isCancelled else { return }
                manifest = loaded.0; videoURL = loaded.1; audioURL = loaded.2
                bundleURL = loaded.3
                if (manifest?.video != nil && videoURL == nil) || (manifest?.audio != nil && audioURL == nil)
                    || (videoURL == nil && audioURL == nil) { message = "Saved media file is missing" }
            } catch {
                if !Task.isCancelled { message = error.localizedDescription }
            }
        }
        .task(id: "\(mode)-\(videoURL?.path ?? "none")-\(audioURL?.path ?? "none")") {
            player?.pause(); player = nil
            guard !Task.isCancelled, mode == "Screen" || audioURL == nil, let videoURL else { return }
            player = AVPlayer(url: videoURL)
        }
        .task { await controller.reload(requestedID: selectedID) }
        .onDisappear { player?.pause(); player = nil }
        .confirmationDialog("Delete this capture and all its files?", isPresented: $confirmDelete) {
            Button("Delete capture", role: .destructive) {
                guard let id = selected?.id else { return }
                Task {
                    do {
                        try await controller.delete(id: id)
                        if selectedID == id { selectedID = nil }
                    }
                    catch { message = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
