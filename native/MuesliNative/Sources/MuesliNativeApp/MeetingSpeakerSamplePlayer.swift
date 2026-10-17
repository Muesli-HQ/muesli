import AVFoundation
import Foundation
import MuesliCore
import Observation

@MainActor @Observable
final class MeetingSpeakerSamplePlayer {
    var playingKey: MeetingSpeakerKey?
    var error: String?
    private var generation = UUID()
    private var player: AVPlayer?
    private var boundary: Any?

    func stop() {
        generation = UUID()
        if let boundary, let player { player.removeTimeObserver(boundary) }
        boundary = nil; player?.pause(); player = nil; playingKey = nil
    }

    func play(key: MeetingSpeakerKey, range: MeetingSpeakerSampleRange, path: String) async {
        stop(); error = nil
        let token = generation
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        do {
            let duration = try await asset.load(.duration).seconds
            guard generation == token, !Task.isCancelled else { return }
            let end = min(duration, range.end)
            guard duration.isFinite, duration > 0, range.start.isFinite,
                  range.start >= 0, end.isFinite, end > range.start else { throw CocoaError(.fileReadCorruptFile) }
            let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            self.player = player; playingKey = key
            boundary = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: end, preferredTimescale: 600))], queue: .main) { [weak self] in
                Task { @MainActor in if self?.generation == token { self?.stop() } }
            }
            let didSeek = await player.seek(to: CMTime(seconds: range.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            guard generation == token, !Task.isCancelled else { return }
            guard didSeek else { stop(); error = "The sample position could not be loaded."; return }
            player.play()
        } catch {
            guard generation == token else { return }
            stop(); self.error = "The saved recording could not be played."
        }
    }
}
