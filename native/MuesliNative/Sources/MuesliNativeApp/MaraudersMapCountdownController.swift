import Foundation
import AppKit

/// Orchestrates the 30-second pre-meeting countdown for the Marauder's Map easter egg.
/// Uses a two-phase timer: lightweight 5-second polling to detect the window,
/// then 1-second ticks for the live countdown display + audio playback.
@MainActor
final class MaraudersMapCountdownController {
    private var timer: Timer?
    private var activeEventID: String?
    private var eventProvider: (() -> (id: String, title: String, startDate: Date)?)?
    private var audioClipID: String = "bbc_world_news"
    private var customAudioPath: String?
    private var onStatusBarUpdate: ((String?) -> Void)?
    private var onCountdownFinished: (((id: String, title: String, startDate: Date)) -> Void)?

    func startMonitoring(
        eventProvider: @escaping () -> (id: String, title: String, startDate: Date)?,
        audioClipID: String,
        customAudioPath: String?,
        onStatusBarUpdate: @escaping (String?) -> Void,
        onCountdownFinished: @escaping ((id: String, title: String, startDate: Date)) -> Void
    ) {
        self.eventProvider = eventProvider
        self.audioClipID = audioClipID
        self.customAudioPath = customAudioPath
        self.onStatusBarUpdate = onStatusBarUpdate
        self.onCountdownFinished = onCountdownFinished
        startPolling()
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        activeEventID = nil
        SoundController.stopMaraudersMapClip()
        onStatusBarUpdate?(nil)
    }

    func updateAudioClip(_ clipID: String, customPath: String?) {
        audioClipID = clipID
        customAudioPath = customPath
    }

    // MARK: - Phase 1: lightweight polling

    private func startPolling() {
        timer?.invalidate()

        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollCheck()
            }
        }
        pollCheck()
    }

    private func pollCheck() {
        guard let event = eventProvider?() else { return }
        let secondsUntil = event.startDate.timeIntervalSinceNow

        if secondsUntil <= 35 && secondsUntil > 0 && activeEventID != event.id {
            activeEventID = event.id
            beginCountdown(event: event)
        }
    }

    // MARK: - Phase 2: 1-second countdown

    private func beginCountdown(event: (id: String, title: String, startDate: Date)) {
        timer?.invalidate()

        SoundController.playMaraudersMapClip(id: audioClipID, customPath: customAudioPath)

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self else { t.invalidate(); return }
                self.tick(event: event, timer: t)
            }
        }
        // Fire immediately for the first tick
        tick(event: event, timer: nil)
    }

    private func tick(event: (id: String, title: String, startDate: Date), timer maybeTimer: Timer?) {
        let remaining = Int(ceil(event.startDate.timeIntervalSinceNow))

        if remaining <= 0 {
            maybeTimer?.invalidate()
            SoundController.stopMaraudersMapClip()
            onStatusBarUpdate?(nil)
            onCountdownFinished?((id: event.id, title: event.title, startDate: event.startDate))
            activeEventID = nil
            startPolling()
            return
        }

        let truncatedTitle = event.title.count > 15
            ? String(event.title.prefix(13)) + "\u{2026}"
            : event.title
        onStatusBarUpdate?(" \(truncatedTitle) 0:\(String(format: "%02d", remaining))")
    }
}
