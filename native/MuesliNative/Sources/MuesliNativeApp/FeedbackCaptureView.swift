import SwiftUI
import AVKit
import MuesliCore

struct FeedbackCaptureView: View {
    struct Loaded: @unchecked Sendable {
        let manifest: FeedbackCaptureManifest
        let video: URL?, audio: URL?, bundle: URL
        let active: Bool
        let contactSheet: NSImage?
        let frames: [String: NSImage]
        let summaryAvailable: Bool
        let missingArtifacts: [String]
    }
    nonisolated static func load(id: String, store: FeedbackCaptureStore) throws -> Loaded {
        try Task.checkCancellation()
        let manifest = try store.manifest(id: id)
        var missing: [String] = []
        func existing(_ path: String?) throws -> URL? {
            guard let path else { return nil }
            let url = try store.mediaURL(id: id, path: path)
            guard FileManager.default.fileExists(atPath: url.path) else { missing.append(path); return nil }
            return url
        }
        func image(_ path: String?) throws -> NSImage? {
            try Task.checkCancellation()
            guard let path, let url = try existing(path) else { return nil }
            guard let data = try? Data(contentsOf: url), let bitmap = NSBitmapImageRep(data: data) else {
                missing.append(path); return nil
            }
            let image = NSImage(size: bitmap.size); image.addRepresentation(bitmap)
            return image
        }
        let sheet = try image(manifest.contactSheet)
        var frames: [String: NSImage] = [:]
        for frame in manifest.keyframes { frames[frame.file] = try image(frame.file) }
        let video = try existing(manifest.video), audio = try existing(manifest.audio)
        let summary = try store.mediaURL(id: id, path: "summary.md")
        try Task.checkCancellation()
        return Loaded(manifest: manifest, video: video, audio: audio, bundle: try store.bundleURL(id: id),
            active: store.isActive(id: id), contactSheet: sheet, frames: frames,
            summaryAvailable: FileManager.default.fileExists(atPath: summary.path), missingArtifacts: missing)
    }
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
    @State private var contactSheet: NSImage?
    @State private var frames: [String: NSImage] = [:]
    @State private var summaryAvailable = false
    @State private var copyTask: Task<Void, Never>?
    @State private var copyMessage: String?
    private var selected: FeedbackCaptureRecord? { selectedID == nil ? controller.records.first : controller.records.first { $0.id == selectedID } }

    var body: some View {
        ScrollView {
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
                    if let contactSheet {
                        Image(nsImage: contactSheet).resizable().scaledToFit().frame(maxHeight: 150)
                            .accessibilityLabel("Scrawl contact sheet")
                    }
                    if let manifest, !manifest.keyframes.isEmpty {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(manifest.keyframes, id: \.index) { frame in
                                    HStack(alignment: .top, spacing: 12) {
                                        if let image = frames[frame.file] {
                                            Image(nsImage: image).resizable().scaledToFit().frame(width: 220)
                                                .accessibilityLabel("Frame \(frame.index)")
                                        } else { Label("Frame unavailable", systemImage: "photo").frame(width: 220) }
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(String(format: "#%d · %d:%02d", frame.index, frame.t / 60_000, (frame.t / 1000) % 60)).font(.headline)
                                            Text(frame.said.isEmpty ? "No narration for this frame" : frame.said)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }.textSelection(.enabled)
                        }.frame(maxHeight: 220)
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
                    if let manifest {
                        let narration = FeedbackCaptureContext.unillustratedNarration(manifest)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(!manifest.keyframes.isEmpty && !narration.text.isEmpty ? "Unillustrated narration" : "Narration").font(.headline)
                                if narration.estimated {
                                    Text("Estimated timing").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if let reason = narration.missingReason {
                                Text("No transcript: \(reason)").foregroundStyle(.secondary)
                            } else if let transcript = manifest.transcript {
                                if !narration.text.isEmpty {
                                    ScrollView {
                                        VStack(alignment: .leading, spacing: 8) {
                                            if manifest.keyframes.isEmpty && !transcript.segments.isEmpty {
                                                ForEach(Array(transcript.segments.enumerated()), id: \.offset) { _, segment in
                                                    Text(String(format: "%d:%02d  %@", segment.t0 / 60_000,
                                                        (segment.t0 / 1000) % 60, segment.text))
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                }
                                            } else {
                                                Text(narration.text).frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                        }.textSelection(.enabled)
                                    }.frame(maxHeight: 100)
                                }
                            } else {
                                Text(selected.state == .processing ? "Transcribing narration…" : "No transcript saved")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text(manifest?.state.rawValue.capitalized ?? selected.state.rawValue.capitalized).font(.headline)
                    if manifest?.audio == nil, manifest?.video != nil { Text("Video only · narration unavailable").foregroundStyle(.secondary) }
                    if manifest?.video == nil, manifest?.audio != nil { Text("Audio only · video unavailable").foregroundStyle(.secondary) }
                    ForEach(Array((manifest?.failures ?? []).enumerated()), id: \.offset) { _, failure in
                        Text("\(failure.stage): \(failure.message)").font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        Button("Copy") { copy(selected.id) }
                            .disabled(loading || activeWriter || !summaryAvailable)
                        if let copyMessage { Text(copyMessage).font(.caption).foregroundStyle(.secondary) }
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
        }
        .task(id: "\(selected?.id ?? "none")-\(selected?.state.rawValue ?? "none")-\(controller.hasAttempt)-\(controller.recoveryRevision)") {
            loading = true; player?.pause(); player = nil; manifest = nil; message = nil; bundleURL = nil
            videoURL = nil; audioURL = nil; mode = "Screen"
            contactSheet = nil; frames = [:]; summaryAvailable = false; copyTask?.cancel(); copyMessage = nil
            defer { if !Task.isCancelled { loading = false } }
            guard let id = selected?.id, let store = controller.store else { return }
            let isActive = await Task.detached { store.isActive(id: id) }.value
            guard !Task.isCancelled else { return }
            activeWriter = isActive
            do {
                let loader = Task.detached(priority: .utility) { try Self.load(id: id, store: store) }
                let loaded = try await withTaskCancellationHandler { try await loader.value } onCancel: { loader.cancel() }
                guard !Task.isCancelled else { return }
                manifest = loaded.manifest; videoURL = loaded.video; audioURL = loaded.audio
                bundleURL = loaded.bundle; activeWriter = loaded.active
                contactSheet = loaded.contactSheet; frames = loaded.frames; summaryAvailable = loaded.summaryAvailable
                if !loaded.missingArtifacts.isEmpty { message = "Missing or unreadable: " + loaded.missingArtifacts.joined(separator: ", ") }
                else if videoURL == nil && audioURL == nil && loaded.manifest.events.isEmpty { message = "Saved media file is missing" }
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
        .onDisappear { player?.pause(); player = nil; copyTask?.cancel() }
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
    private func copy(_ id: String) {
        copyTask?.cancel(); copyMessage = nil
        copyTask = Task {
            let result = await controller.copy(id: id)
            guard !Task.isCancelled, selected?.id == id else { return }
            copyMessage = result == .copied ? "Copied" : result == .failed ? "Copy failed" : nil
        }
    }

}
