import AppKit
import Darwin
import Foundation

protocol MediaPlaybackManaging: AnyObject {
    func beginDictationMediaPause(enabled: Bool, routeKind: AudioOutputRouteKind)
    func restoreDictationMediaPause()
}

/// What we are trying to achieve, not how it is delivered. The only transport
/// that works across every player is the hardware play/pause key, which is a
/// *toggle*; the intent is what decides whether that toggle should be sent at
/// all, and what state we then verify against.
enum MediaPlaybackCommand: String, Equatable, CustomStringConvertible {
    case pause
    case play

    var description: String { rawValue }

    var targetState: MediaPlaybackState {
        switch self {
        case .pause: return .notPlaying
        case .play: return .playing
        }
    }
}

/// Actual playback state of the system now-playing application, as opposed to
/// `AudioOutputActivityStatus`, which only reflects whether an app's audio
/// output pipeline is running. Browsers and most video players keep their
/// audio engine/IO alive while a video is *paused*, so `IsRunningOutput` (and
/// therefore `AudioOutputActivityStatus`) reports "active" for paused media
/// and cannot be used to decide whether to send a media command.
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

    /// Sends one hardware-equivalent play/pause toggle. `intent` is diagnostic
    /// only — the delivered event is identical in both directions, which is why
    /// callers must confirm the resulting state rather than assume it.
    func sendPlayPauseToggle(intent: MediaPlaybackCommand)
}

/// Pauses whatever is playing for the duration of a dictation and puts it back
/// afterwards.
///
/// Every transition is *verified*: query the now-playing state, send a toggle
/// only if the state disagrees with the goal, then poll until the system
/// confirms the new state, retrying the toggle once if it was dropped. Media
/// commands on macOS report success far more readily than they take effect, so
/// an unverified send is indistinguishable from a no-op. See
/// `SystemMediaPlaybackClient` for why the toggle is the only usable transport.
final class MediaPlaybackController: MediaPlaybackManaging {
    struct VerificationPolicy {
        /// Total toggles per transition, including the first.
        var maxToggleAttempts: Int
        /// State polls per toggle before that toggle is considered lost.
        var pollsPerAttempt: Int
        var pollInterval: DispatchTimeInterval

        static let `default` = VerificationPolicy(
            maxToggleAttempts: 2,
            pollsPerAttempt: 12,
            pollInterval: .milliseconds(80)
        )
    }

    private enum PauseState: Equatable {
        case idle
        /// Query in flight; we have not yet touched playback.
        case checkingBegin(Int)
        /// We sent a pause for this session and owe a resume.
        case paused(Int)
    }

    private let client: MediaPlaybackClient
    private let queue: DispatchQueue
    private let policy: VerificationPolicy
    private var pauseState: PauseState = .idle
    private var generation = 0
    private var inFlight = 0

    init(
        client: MediaPlaybackClient = SystemMediaPlaybackClient(),
        queue: DispatchQueue = DispatchQueue(label: "com.muesli.media-playback"),
        policy: VerificationPolicy = .default
    ) {
        self.client = client
        self.queue = queue
        self.policy = policy
    }

    func beginDictationMediaPause(enabled: Bool, routeKind: AudioOutputRouteKind) {
        queue.async { [self] in
            guard enabled else { return }
            guard routeKind == .speakerLike else { return }

            switch pauseState {
            case .checkingBegin:
                // A query for this session is already in flight.
                return
            case .paused:
                // A previous session never got its restore — a cancelled or
                // errored dictation, or a release we never saw. Without this,
                // the controller would sit in `.paused` forever and silently
                // stop pausing for every future dictation.
                MediaPlaybackLogging.log("begin found stale paused state; re-arming")
                pauseState = .idle
                startBeginPlaybackCheck()
            case .idle:
                startBeginPlaybackCheck()
            }
        }
    }

    func restoreDictationMediaPause() {
        queue.async { [self] in
            switch pauseState {
            case let .checkingBegin(token):
                // The user released before we confirmed active playback. Cancel
                // the pending pause so a late callback cannot start media.
                guard token == generation else { return }
                MediaPlaybackLogging.log("restore cancelled pending pause")
                pauseState = .idle
                generation += 1
            case let .paused(token):
                guard token == generation else { return }
                pauseState = .idle
                ensure(.play, token: token)
            case .idle:
                return
            }
        }
    }

    private func startBeginPlaybackCheck() {
        generation += 1
        let token = generation
        pauseState = .checkingBegin(token)
        beginOperation()
        client.nowPlayingPlaybackState { [weak self] playbackState in
            self?.queue.async {
                self?.handleBeginPlaybackState(playbackState, token: token)
                self?.endOperation()
            }
        }
    }

    private func handleBeginPlaybackState(_ playbackState: MediaPlaybackState, token: Int) {
        guard pauseState == .checkingBegin(token), token == generation else { return }
        // Only pause when we can positively confirm something is actually
        // playing. Unknown is also a no-op so an unavailable state signal cannot
        // toggle already-paused media into playing.
        guard playbackState == .playing else {
            MediaPlaybackLogging.log("begin skipped state=\(playbackState)")
            pauseState = .idle
            return
        }
        pauseState = .paused(token)
        ensure(.pause, token: token)
    }

    /// Drives playback to `command.targetState`, verifying and retrying.
    private func ensure(_ command: MediaPlaybackCommand, token: Int) {
        beginOperation()
        attempt(command, token: token, attemptsRemaining: policy.maxToggleAttempts) { [weak self] settled in
            guard let self else { return }
            MediaPlaybackLogging.log("\(command) settled=\(settled)")
            self.endOperation()
        }
    }

    private func attempt(
        _ command: MediaPlaybackCommand,
        token: Int,
        attemptsRemaining: Int,
        completion: @escaping (Bool) -> Void
    ) {
        guard token == generation else {
            completion(false)
            return
        }
        client.nowPlayingPlaybackState { [weak self] state in
            self?.queue.async {
                guard let self, token == self.generation else {
                    completion(false)
                    return
                }
                if state == command.targetState {
                    completion(true)
                    return
                }
                // Never toggle on an unreadable state: a blind toggle would be
                // as likely to start silent media as to stop playing media.
                guard state != .unknown else {
                    MediaPlaybackLogging.log("\(command) abandoned state=unknown")
                    completion(false)
                    return
                }
                guard attemptsRemaining > 0 else {
                    completion(false)
                    return
                }
                self.client.sendPlayPauseToggle(intent: command)
                self.poll(
                    command,
                    token: token,
                    attemptsRemaining: attemptsRemaining - 1,
                    pollsRemaining: self.policy.pollsPerAttempt,
                    completion: completion
                )
            }
        }
    }

    private func poll(
        _ command: MediaPlaybackCommand,
        token: Int,
        attemptsRemaining: Int,
        pollsRemaining: Int,
        completion: @escaping (Bool) -> Void
    ) {
        guard pollsRemaining > 0 else {
            // The toggle never landed. Re-read and try once more.
            MediaPlaybackLogging.log("\(command) toggle unconfirmed; retrying")
            attempt(command, token: token, attemptsRemaining: attemptsRemaining, completion: completion)
            return
        }
        queue.asyncAfter(deadline: .now() + policy.pollInterval) { [weak self] in
            guard let self, token == self.generation else {
                completion(false)
                return
            }
            self.client.nowPlayingPlaybackState { state in
                self.queue.async {
                    guard token == self.generation else {
                        completion(false)
                        return
                    }
                    if state == command.targetState {
                        completion(true)
                        return
                    }
                    self.poll(
                        command,
                        token: token,
                        attemptsRemaining: attemptsRemaining,
                        pollsRemaining: pollsRemaining - 1,
                        completion: completion
                    )
                }
            }
        }
    }

    private func beginOperation() {
        inFlight += 1
    }

    private func endOperation() {
        inFlight -= 1
    }

    /// Test hook: blocks until no verification work remains outstanding.
    func waitForIdle(timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var busy = true
            queue.sync { busy = inFlight > 0 }
            if !busy { return }
            usleep(1_000)
        }
    }
}

/// Reads playback state through MediaRemote and changes it with the hardware
/// play/pause key.
///
/// The asymmetry is deliberate and was measured on macOS 26.5.2:
///
/// - *Reading* now-playing state through MediaRemote works, but only from an
///   Apple-signed host process. Called directly from this (third-party signed)
///   app the C entry points return success and deliver nothing, so the query is
///   shelled out through `osascript`.
/// - *Writing* through MediaRemote is not usable at all.
///   `MRNowPlayingController.localRouteController` accepts `pause` but silently
///   ignores `play` and `togglePlayPause`, and `MRMediaRemoteSendCommand`
///   returns `true` for every command while doing nothing. A media client that
///   trusts those return values pauses fine and then never resumes.
/// - The one transport every player honours — native and Electron alike — is
///   the `NX_KEYTYPE_PLAY` HID event the physical F8 key produces. Electron
///   apps such as Plexamp bind media keys via `globalShortcut` and register no
///   MediaRemote command handlers at all, so this is the only path that reaches
///   them.
///
/// That key is a toggle with no acknowledgement, which is why
/// `MediaPlaybackController` verifies every transition rather than assuming it.
final class SystemMediaPlaybackClient: MediaPlaybackClient {
    private let jxa = MediaRemoteJXAClient()
    private let nowPlaying = NowPlayingMediaRemoteClient()

    func nowPlayingPlaybackState(completion: @escaping (MediaPlaybackState) -> Void) {
        jxa.playbackState { [weak self] result in
            switch result {
            case let .available(state, appName):
                MediaPlaybackLogging.log("query backend=jxa state=\(state) app=\(appName ?? "unknown")")
                completion(state)
            case let .unavailable(reason):
                self?.nowPlaying.playbackState { state in
                    MediaPlaybackLogging.log("query backend=media-remote state=\(state) fallback_reason=\(reason)")
                    completion(state)
                }
            }
        }
    }

    /// `NX_KEYTYPE_PLAY` from IOKit's `ev_keymap.h`.
    private static let nxKeyTypePlay = 16

    func sendPlayPauseToggle(intent: MediaPlaybackCommand) {
        MediaPlaybackLogging.log("toggle intent=\(intent) backend=hid-key")
        postAuxKey(keyCode: Self.nxKeyTypePlay)
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

private enum MediaPlaybackLogging {
    static func log(_ message: String) {
        fputs("[media-playback] \(message)\n", stderr)
    }
}

private enum MediaRemoteJXAPlaybackStateResult {
    case available(MediaPlaybackState, appName: String?)
    case unavailable(String)
}

/// Reads the now-playing state through the Objective-C MediaRemote classes
/// hosted in `osascript`. The framework gates its clients on the host binary,
/// so an Apple-signed interpreter can read state that this app cannot read
/// in-process.
private final class MediaRemoteJXAClient {
    private struct PlaybackPayload: Decodable {
        let available: Bool
        let state: String?
        let appName: String?
        let reason: String?
    }

    private enum ExecutionResult {
        case success(String)
        case failure(String)
    }

    private let queue = DispatchQueue(label: "com.muesli.media-playback.jxa")
    private let queryTimeout: DispatchTimeInterval = .milliseconds(750)

    func playbackState(completion: @escaping (MediaRemoteJXAPlaybackStateResult) -> Void) {
        run(script: Self.queryScript) { result in
            switch result {
            case let .failure(reason):
                completion(.unavailable(reason))
            case let .success(output):
                guard let data = output.data(using: .utf8) else {
                    completion(.unavailable("output_encoding"))
                    return
                }
                do {
                    let payload = try JSONDecoder().decode(PlaybackPayload.self, from: data)
                    guard payload.available else {
                        completion(.unavailable(payload.reason ?? "media-remote_unavailable"))
                        return
                    }
                    let state: MediaPlaybackState
                    switch payload.state {
                    case "playing":
                        state = .playing
                    case "not-playing":
                        state = .notPlaying
                    default:
                        state = .unknown
                    }
                    completion(.available(state, appName: payload.appName))
                } catch {
                    completion(.unavailable("invalid_output=\(error.localizedDescription)"))
                }
            }
        }
    }

    private func run(
        script: String,
        arguments: [String] = [],
        completion: @escaping (ExecutionResult) -> Void
    ) {
        queue.async { [self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", script, "--"] + arguments
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            let terminationSemaphore = DispatchSemaphore(value: 0)
            var terminationStatus: Int32 = -1
            process.terminationHandler = { terminatedProcess in
                terminationStatus = terminatedProcess.terminationStatus
                terminationSemaphore.signal()
            }

            do {
                try process.run()
            } catch {
                completion(.failure("launch=\(error.localizedDescription)"))
                return
            }

            if terminationSemaphore.wait(timeout: .now() + queryTimeout) == .timedOut {
                if process.isRunning {
                    process.terminate()
                }
                if terminationSemaphore.wait(timeout: .now() + .milliseconds(250)) == .timedOut,
                   process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = terminationSemaphore.wait(timeout: .now() + .milliseconds(250))
                }
                completion(.failure("timeout"))
                return
            }

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard terminationStatus == 0 else {
                let detail = errorOutput.isEmpty ? "exit=\(terminationStatus)" : errorOutput
                completion(.failure(detail))
                return
            }
            completion(.success(output))
        }
    }

    private static let queryScript = """
    ObjC.import('Foundation');

    function run() {
      const framework = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/');
      if (!framework || !framework.load) return JSON.stringify({available: false, reason: 'framework'});
      framework.load;
      const request = $.NSClassFromString('MRNowPlayingRequest');
      if (!request) return JSON.stringify({available: false, reason: 'request-class'});

      const playerPath = request.localNowPlayingPlayerPath;
      const item = request.localNowPlayingItem;
      if (!playerPath || !item) return JSON.stringify({available: true, state: 'unknown', appName: null});

      const info = item.nowPlayingInfo;
      const rateObject = info && info.objectForKey
        ? info.objectForKey('kMRMediaRemoteNowPlayingInfoPlaybackRate')
        : null;
      const rate = rateObject ? rateObject.js : null;
      let appName = null;
      try {
        const client = playerPath.client;
        if (client && client.displayName) appName = client.displayName.js;
      } catch (_) {}

      const state = typeof rate === 'number'
        ? (rate > 0 ? 'playing' : 'not-playing')
        : 'unknown';
      return JSON.stringify({available: true, state: state, appName: appName});
    }
    """
}

/// In-process MediaRemote read, used only when the `osascript` route is
/// unavailable. On macOS releases that gate MediaRemote on the host binary this
/// returns `.unknown` rather than a wrong answer.
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
