import Foundation
import AVFoundation

/// Plays a ``KittenTTSResult`` through the device speakers.
///
/// On iOS the audio session is configured for `.playback` before playback starts.
/// On macOS no session management is required.
///
/// Audio playback is skipped gracefully in headless environments (e.g. simulator
/// CI without audio hardware), where ``isAudioAvailable()`` returns `false`.
final class AudioOutput: NSObject {

    private var player: AVAudioPlayer?

    // MARK: - Playback

    /// Play `samples` at `sampleRate` Hz through the device speakers.
    ///
    /// Returns as soon as playback completes (or is skipped due to no hardware).
    ///
    /// - Parameters:
    ///   - samples: Float32 PCM mono audio samples.
    ///   - sampleRate: Sample rate in Hz (e.g. 24 000).
    /// - Throws: ``KittenTTSError/audioSessionFailed(_:)`` if the session cannot be
    ///   configured, or ``KittenTTSError/playbackFailed(_:)`` if the player fails.
    func play(samples: [Float], sampleRate: Int) async throws {
        guard Self.isAudioAvailable() else { return }

        let wavData = WAVEncoder.encode(samples: samples, sampleRate: sampleRate)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                self.startPlayback(wavData: wavData, continuation: cont)
            }
        }
    }

    /// Stop any currently active playback.
    func stop() {
        DispatchQueue.main.async {
            self.finishPlayback(.success(()), stopPlayer: true)
        }
    }

    // MARK: - Private

    private var continuation: CheckedContinuation<Void, Error>?

    private func startPlayback(wavData: Data, continuation cont: CheckedContinuation<Void, Error>) {
        dispatchPrecondition(condition: .onQueue(.main))

        if continuation != nil {
            finishPlayback(.success(()), stopPlayer: true)
        }

        do {
#if os(iOS)
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                cont.resume(throwing: KittenTTSError.audioSessionFailed(error.localizedDescription))
                return
            }
#endif
            let p = try AVAudioPlayer(data: wavData)
            p.delegate = self
            p.prepareToPlay()
            player = p

            // Stash continuation so the delegate can resume it on completion.
            continuation = cont

            p.play()
        } catch {
            cont.resume(throwing: KittenTTSError.playbackFailed(error.localizedDescription))
        }
    }

    private func finishPlayback(_ result: Result<Void, Error>, stopPlayer: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))

        let cont = continuation
        continuation = nil
        if stopPlayer {
            player?.stop()
        }
        player = nil

        switch result {
        case .success:
            cont?.resume()
        case .failure(let error):
            cont?.resume(throwing: error)
        }
    }

    private func finishPlaybackOnMain(_ result: Result<Void, Error>, stopPlayer: Bool) {
        if Thread.isMainThread {
            finishPlayback(result, stopPlayer: stopPlayer)
        } else {
            DispatchQueue.main.async {
                self.finishPlayback(result, stopPlayer: stopPlayer)
            }
        }
    }

    // MARK: - Audio availability

    /// Returns `false` in headless simulator environments where coreaudiod is absent.
    static func isAudioAvailable() -> Bool {
#if os(iOS) && targetEnvironment(simulator)
        let session = AVAudioSession.sharedInstance()
        do { try session.setCategory(.ambient) } catch { return false }
        return !session.currentRoute.outputs.isEmpty
#else
        return true
#endif
    }
}

// Mutable playback state is serialized through DispatchQueue.main.
extension AudioOutput: @unchecked Sendable {}

// MARK: - AVAudioPlayerDelegate

extension AudioOutput: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if flag {
            finishPlaybackOnMain(.success(()), stopPlayer: false)
        } else {
            finishPlaybackOnMain(.failure(KittenTTSError.playbackFailed("Playback ended early")), stopPlayer: false)
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finishPlaybackOnMain(
            .failure(KittenTTSError.playbackFailed(error?.localizedDescription ?? "Decode error")),
            stopPlayer: false
        )
    }
}
