import AppKit
import AudioToolbox

/// Plays subtle sounds for dictation and Quill lifecycle events.
/// Sounds are skipped when `soundEnabled` is false.
@MainActor
enum SoundController {
    static func prewarmLifecycleSounds() {
        SystemSoundPlayer.prewarm(names: ["Tink", "Purr", "Glass"])
        let quillSounds = ["quill-activate", "quill-release"].compactMap { name in
            bundledLifecycleSoundURL(named: name).map { (name, $0) }
        }
        SystemSoundPlayer.prewarmBundled(quillSounds)
    }

    static func playDictationStart(enabled: Bool) {
        guard enabled else { return }
        SystemSoundPlayer.play(named: "Tink")
    }

    static func playDictationInsert(enabled: Bool) {
        guard enabled else { return }
        SystemSoundPlayer.play(named: "Purr")
    }

    static func playQuillStart(enabled: Bool) {
        guard enabled, let url = bundledLifecycleSoundURL(named: "quill-activate") else { return }
        SystemSoundPlayer.playBundled(named: "quill-activate", url: url)
    }

    static func playQuillRelease(enabled: Bool) {
        guard enabled, let url = bundledLifecycleSoundURL(named: "quill-release") else { return }
        SystemSoundPlayer.playBundled(named: "quill-release", url: url)
    }

    static func playModelReady(enabled: Bool) {
        guard enabled else { return }
        SystemSoundPlayer.play(named: "Glass")
    }

    // MARK: - Marauder's Map

    /// Bundled preset clips (shipped with the app).
    static let maraudersMapPresets: [(id: String, label: String)] = [
        ("bbc_world_news", "BBC World News"),
        ("ndtv", "NDTV"),
    ]

    /// ID used in config when the user has loaded a custom file.
    static let customClipID = "custom"

    /// All dropdown options: presets + custom.
    static var maraudersMapClipLabels: [String] {
        maraudersMapPresets.map(\.label) + ["Custom\u{2026}"]
    }

    /// Resolve a clip ID to a display label.
    static func labelForClip(id: String, customPath: String?) -> String {
        if id == customClipID {
            if let path = customPath {
                return URL(fileURLWithPath: path).lastPathComponent
            }
            return "Custom\u{2026}"
        }
        return maraudersMapPresets.first(where: { $0.id == id })?.label ?? "BBC World News"
    }

    private static var currentClipSound: NSSound?
    private static var soundDelegate: ClipSoundDelegate?

    static var isClipPlaying: Bool {
        currentClipSound?.isPlaying ?? false
    }

    static func playMaraudersMapClip(id: String, customPath: String?, onFinished: (() -> Void)? = nil) {
        stopMaraudersMapClip()

        let url: URL?
        if id == customClipID, let path = customPath {
            url = URL(fileURLWithPath: path)
        } else {
            url = resolvePresetURL(id: id)
        }

        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            fputs("[muesli-native] Marauder's Map audio clip not found: \(id)\n", stderr)
            return
        }

        let sound = NSSound(contentsOf: url, byReference: true)
        if let onFinished {
            let delegate = ClipSoundDelegate(onFinished: onFinished)
            sound?.delegate = delegate
            soundDelegate = delegate
        }
        sound?.play()
        currentClipSound = sound
    }

    static func stopMaraudersMapClip() {
        currentClipSound?.stop()
        currentClipSound = nil
        soundDelegate = nil
    }

    static func playMaraudersMapUnlock() {
        SystemSoundPlayer.play(named: "Glass")
    }

    /// Copy a user-selected file into the app's support directory and return the destination path.
    static func importCustomClip(from sourceURL: URL, supportDir: URL) throws -> String {
        let audioDir = supportDir.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)

        // Use a stable filename ("custom.<ext>") to avoid accumulating old imports
        let ext = sourceURL.pathExtension
        let dest = audioDir.appendingPathComponent("custom.\(ext)")
        // Atomic replacement: copy to temp, then move
        let tmp = audioDir.appendingPathComponent("custom_import_\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: sourceURL, to: tmp)
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
        return dest.path
    }

    private static func resolvePresetURL(id: String) -> URL? {
        for ext in ["mp3", "m4a", "wav"] {
            if let url = Bundle.main.url(forResource: id, withExtension: ext, subdirectory: "audio") {
                return url
            }
        }
        return nil
    }

    static func bundledLifecycleSoundURL(named name: String) -> URL? {
        for ext in ["wav", "aiff", "mp3"] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "audio") {
                return url
            }
        }

        // Source-tree fallback keeps focused SwiftPM tests independent of app staging.
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            for ext in ["wav", "aiff", "mp3"] {
                let candidate = directory.appendingPathComponent("assets/audio/\(name).\(ext)")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}

private enum SystemSoundPlayer {
    private static let queue = DispatchQueue(label: "com.muesli.system-sound-player", qos: .userInitiated)
    private static var soundIDs: [String: SystemSoundID] = [:]
    private static var cleanupRegistered = false

    static func prewarm(names: [String]) {
        queue.async {
            registerCleanupIfNeeded()
            for name in names {
                _ = loadSystemSoundID(named: name)
            }
        }
    }

    static func prewarmBundled(_ sounds: [(name: String, url: URL)]) {
        queue.async {
            registerCleanupIfNeeded()
            for sound in sounds {
                _ = loadSoundID(at: sound.url, cacheKey: "bundled:\(sound.name)")
            }
        }
    }

    static func play(named name: String) {
        queue.async {
            registerCleanupIfNeeded()
            guard let soundID = loadSystemSoundID(named: name) else { return }
            AudioServicesPlaySystemSound(soundID)
        }
    }

    static func playBundled(named name: String, url: URL) {
        queue.async {
            registerCleanupIfNeeded()
            guard let soundID = loadSoundID(at: url, cacheKey: "bundled:\(name)") else { return }
            AudioServicesPlaySystemSound(soundID)
        }
    }

    private static func registerCleanupIfNeeded() {
        guard !cleanupRegistered else { return }
        cleanupRegistered = true
        atexit {
            SystemSoundPlayer.disposeCachedSoundsBestEffort()
        }
    }

    private static func disposeCachedSoundsBestEffort() {
        queue.sync {
            for soundID in soundIDs.values {
                AudioServicesDisposeSystemSoundID(soundID)
            }
            soundIDs.removeAll()
        }
    }

    private static func loadSystemSoundID(named name: String) -> SystemSoundID? {
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        return loadSoundID(at: url, cacheKey: "system:\(name)")
    }

    private static func loadSoundID(at url: URL, cacheKey: String) -> SystemSoundID? {
        if let soundID = soundIDs[cacheKey] {
            return soundID
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var soundID: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(url as CFURL, &soundID)
        guard status == kAudioServicesNoError else {
            fputs("[muesli-native] failed to load sound \(url.lastPathComponent): \(status)\n", stderr)
            return nil
        }
        soundIDs[cacheKey] = soundID
        return soundID
    }
}

private class ClipSoundDelegate: NSObject, NSSoundDelegate {
    let onFinished: () -> Void
    init(onFinished: @escaping () -> Void) { self.onFinished = onFinished }

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        Task { @MainActor in self.onFinished() }
    }
}
