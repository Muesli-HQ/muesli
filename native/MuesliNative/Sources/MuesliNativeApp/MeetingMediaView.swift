import SwiftUI
import AVKit
import MuesliCore

struct MeetingMediaView: View {
    let meeting: MeetingRecord
    let controller: MuesliController
    let appState: AppState
    @State private var mode = "Screen"
    @State private var selectedID: String?
    @State private var player: AVPlayer?
    @State private var loadError: String?

    private var memory: VisualMemoryController { controller.visualMemory }
    private var clips: [VisualMemoryItem] {
        memory.items.filter { $0.meetingID == meeting.id && $0.kind == .meetingVideo }.sorted { $0.capturedAt < $1.capturedAt }
    }
    private var hasSeparateAudio: Bool {
        meeting.savedRecordingPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
    }
    private var selected: VisualMemoryItem? { clips.first { $0.id == selectedID } ?? clips.first }
    private var isActive: Bool { controller.activeLiveMeetingRecord()?.id == meeting.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isActive {
                HStack {
                    if memory.recordingMeetingID == meeting.id {
                        Label(memory.pauseState.isPaused ? "Screen paused" : "Recording screen", systemImage: "record.circle")
                            .foregroundStyle(memory.pauseState.isPaused ? Color.secondary : .red)
                        Text(memory.sourceName).lineLimit(1).foregroundStyle(.secondary)
                        Spacer()
                        Button(memory.pauseState.userPaused ? "Resume screen" : "Pause screen") { controller.toggleMeetingScreenPause() }
                            .disabled(memory.isFinalizing || memory.isPreparing || appState.isMeetingRecordingPaused)
                        Button("Stop screen") { controller.stopMeetingScreenRecording() }.disabled(memory.isFinalizing)
                    } else {
                        Button { controller.startMeetingScreenRecording() } label: { Label("Record Screen…", systemImage: "record.circle") }
                            .disabled(memory.isPreparing || memory.isFinalizing || appState.isMeetingRecordingPaused)
                        Text("Screen capture starts only after confirmation").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if memory.isPreparing || memory.isFinalizing {
                HStack { ProgressView().controlSize(.small); Text(memory.isFinalizing ? "Saving screen recording…" : memory.isAwaitingConfirmation ? "Choose a screen to record…" : "Preparing screen recording…") }
            }
            if let message = memory.message {
                HStack { Text(message).font(.caption).foregroundStyle(.orange); Spacer(); Button("Dismiss") { memory.message = nil } }
            }
            if !clips.isEmpty {
                HStack {
                    Label("Video recording", systemImage: "play.rectangle")
                    if hasSeparateAudio {
                        Picker("Media", selection: $mode) { Text("Video").tag("Screen"); Text("Audio").tag("Audio") }
                            .pickerStyle(.segmented).frame(width: 180)
                    }
                    Spacer()
                    Text("\(clips.count) screen clips · Local only").font(.caption).foregroundStyle(.secondary)
                }
            }
            if mode == "Screen" || !hasSeparateAudio, let selected {
                Picker("Screen clip", selection: Binding(get: { selected.id }, set: { selectedID = $0 })) {
                    ForEach(clips) { clip in
                        Text("\(clip.capturedAt.formatted(date: .omitted, time: .standard)) · \(clip.source)").tag(clip.id)
                    }
                }
                if let player { MeetingVideoPlayerView(player: player).frame(minHeight: 220, idealHeight: 330, maxHeight: 400) }
                if let loadError { Text(loadError).foregroundStyle(.secondary) }
                HStack {
                    Text("Recorded interval · \(Int(selected.duration)) seconds").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reveal video") { if let url = memory.mediaURL(selected) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                }
            } else if let path = meeting.savedRecordingPath, FileManager.default.fileExists(atPath: path) {
                MeetingRecordingPlayerView(recordingPath: path)
            } else if !clips.isEmpty {
                Text("Audio is included in each screen clip. Select Screen to play it.").foregroundStyle(.secondary)
            }
        }
        .task(id: "\(mode)-\(hasSeparateAudio)-\(selected?.id ?? "none")") {
            player?.pause(); player = nil; loadError = nil
            guard mode == "Screen" || !hasSeparateAudio, let item = selected, let url = memory.mediaURL(item) else { return }
            guard FileManager.default.fileExists(atPath: url.path) else { loadError = "Screen recording unavailable"; return }
            player = AVPlayer(url: url)
        }
        .onDisappear { player?.pause(); player = nil }
        .onChange(of: clips.count) { _, count in if count > 0 && meeting.savedRecordingPath == nil { mode = "Screen" } }
    }
}

/// Avoid the system _AVKit_SwiftUI VideoPlayer metadata crash on macOS 26.6.2.
/// AppKit owns the transport controls while SwiftUI only hosts the native view.
private struct MeetingVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
