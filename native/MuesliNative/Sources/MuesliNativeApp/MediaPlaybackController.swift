import AppKit
import Darwin
import Foundation

protocol MediaPlaybackManaging: AnyObject {
    func beginDictationMediaPause(enabled: Bool, routeKind: AudioOutputRouteKind)
    func restoreDictationMediaPause()
}

/// Actual playback state of the system now-playing application, as opposed to
/// `AudioOutputActivityStatus`, which only reflects whether an app's audio
/// output pipeline is running. Browsers and most video players keep their
/// audio engine/IO alive while a video is *paused*, so `IsRunningOutput` (and
/// therefore `AudioOutputActivityStatus`) reports "active" for paused media
/// and cannot be used to decide whether to send a play/pause toggle.
enum MediaPlaybackState: Equatable, CustomStringConvertible {
    case playing
    case notPlaying
    case unknown

    var description: String {
        switch self {
        case .playing: return "playing"
        case .notPlaying: return "not-playing"
        case .unknown: return "unknown"
        }
    }
}

protocol MediaPlaybackClient {
    /// Whether the current now-playing application is actually producing audio.
    /// `.unknown` is returned when the signal cannot be obtained.
    func nowPlayingPlaybackState(completion: @escaping (MediaPlaybackState) -> Void)
    func sendMediaPlayPauseToggle()
}

final class MediaPlaybackController: MediaPlaybackManaging {
    private enum PauseState: Equatable {
        case idle
        case checkingBegin(Int)
        case paused
        case checkingRestore(Int)
    }

    private let client: MediaPlaybackClient
    private let queue: DispatchQueue
    private var pauseState: PauseState = .idle
    private var generation = 0

    init(
        client: MediaPlaybackClient = SystemMediaPlaybackClient(),
        queue: DispatchQueue = DispatchQueue(label: "com.muesli.media-playback")
    ) {
        self.client = client
        self.queue = queue
    }

    func beginDictationMediaPause(enabled: Bool, routeKind: AudioOutputRouteKind) {
        queue.async { [self] in
            guard enabled else { return }
            guard routeKind == .speakerLike else { return }
            switch pauseState {
            case .idle:
                generation += 1
                let token = generation
                pauseState = .checkingBegin(token)
                client.nowPlayingPlaybackState { [weak self] playbackState in
                    self?.queue.async {
                        self?.handleBeginPlaybackState(playbackState, token: token)
                    }
                }
            case .checkingRestore:
                // A new dictation began before the previous restore query
                // completed. Keep the media paused and let this new session own
                // the eventual restore instead of briefly resuming playback.
                pauseState = .paused
            case .checkingBegin, .paused:
                return
            }
        }
    }

    func restoreDictationMediaPause() {
        queue.async { [self] in
            switch pauseState {
            case .checkingBegin:
                // The user released before we confirmed active playback. Cancel
                // the pending pause so a late callback cannot start media.
                pauseState = .idle
            case .paused:
                generation += 1
                let token = generation
                pauseState = .checkingRestore(token)
                client.nowPlayingPlaybackState { [weak self] playbackState in
                    self?.queue.async {
                        self?.handleRestorePlaybackState(playbackState, token: token)
                    }
                }
            case .idle, .checkingRestore:
                return
            }
        }
    }

    func waitForIdle() {
        queue.sync {}
        queue.sync {}
    }

    private func handleBeginPlaybackState(_ playbackState: MediaPlaybackState, token: Int) {
        guard pauseState == .checkingBegin(token) else { return }
        // The media key is a blind global toggle: sending it to already-paused
        // media would start playback. Only pause when we can positively confirm
        // something is actually playing. Unknown is also a no-op.
        guard playbackState == .playing else {
            pauseState = .idle
            return
        }
        client.sendMediaPlayPauseToggle()
        pauseState = .paused
    }

    private func handleRestorePlaybackState(_ playbackState: MediaPlaybackState, token: Int) {
        guard pauseState == .checkingRestore(token) else { return }
        pauseState = .idle
        // We only paused media we confirmed was playing, so resume it unless
        // something is actively playing again. Unknown still restores to avoid
        // leaving media stranded after Muesli paused it.
        guard playbackState != .playing else { return }
        client.sendMediaPlayPauseToggle()
    }
}

final class SystemMediaPlaybackClient: MediaPlaybackClient {
    private let nowPlaying = NowPlayingMediaRemoteClient()

    func nowPlayingPlaybackState(completion: @escaping (MediaPlaybackState) -> Void) {
        nowPlaying.playbackState(completion: completion)
    }

    func sendMediaPlayPauseToggle() {
        postAuxKey(keyCode: 16)
    }

    private func postAuxKey(keyCode: Int) {
        postAuxKeyEvent(keyCode: keyCode, keyState: 0xA)
        postAuxKeyEvent(keyCode: keyCode, keyState: 0xB)
    }

    private func postAuxKeyEvent(keyCode: Int, keyState: Int) {
        let data1 = (keyCode << 16) | (keyState << 8)
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(keyState << 8)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        )?.cgEvent else { return }
        event.post(tap: .cghidEventTap)
    }
}

/// Reads the system now-playing playback state through the private MediaRemote
/// framework, loaded lazily via `dlsym`. MediaRemote tracks the application
/// that owns the current "now playing" info and exposes whether it is actually
/// playing — the signal that `kAudioProcessPropertyIsRunningOutput` cannot
/// provide (an app's audio engine stays running while media is paused).
///
/// MediaRemote replies asynchronously. Results are delivered through
/// `DispatchQueue.main` because the XPC-backed callback path is more reliable
/// on a queue with a run loop, and timeout fallback is also asynchronous so
/// dictation start is never blocked on media state detection.
private final class NowPlayingMediaRemoteClient {
    private typealias MRNowPlayingIsPlayingHandler = @convention(block) (Bool) -> Void
    private typealias MRGetNowPlayingIsPlayingFn =
        @convention(c) (DispatchQueue, MRNowPlayingIsPlayingHandler) -> Void

    private let timeoutQueue = DispatchQueue(label: "com.muesli.media-playback.now-playing-timeout")
    private let queryTimeout: DispatchTimeInterval
    private let isPlayingFn: MRGetNowPlayingIsPlayingFn?

    init(queryTimeout: DispatchTimeInterval = .milliseconds(250)) {
        self.queryTimeout = queryTimeout
        // dlopen is globally refcounted by dyld, so the framework stays loaded
        // for the process lifetime; the handle does not need to be retained.
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_NOW | RTLD_LOCAL
        ),
            let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") else {
            self.isPlayingFn = nil
            return
        }
        self.isPlayingFn = unsafeBitCast(symbol, to: MRGetNowPlayingIsPlayingFn.self)
    }

    func playbackState(completion: @escaping (MediaPlaybackState) -> Void) {
        guard let isPlayingFn else {
            completion(.unknown)
            return
        }
        let lock = NSLock()
        var completed = false
        let finish: (MediaPlaybackState) -> Void = { state in
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            lock.unlock()
            completion(state)
        }
        let handler: MRNowPlayingIsPlayingHandler = { value in
            finish(value ? .playing : .notPlaying)
        }
        isPlayingFn(DispatchQueue.main, handler)
        timeoutQueue.asyncAfter(deadline: .now() + queryTimeout) {
            finish(.unknown)
        }
    }
}
