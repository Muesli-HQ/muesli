import AppKit
import AVFoundation
import Foundation
import Observation

struct InteractionPermissionSnapshot: Equatable, Sendable {
    let microphone: Bool
    let accessibility: Bool
    let inputMonitoring: Bool
    let screenRecording: Bool

    var onboardingSnapshot: OnboardingPermissionSnapshot {
        OnboardingPermissionSnapshot(
            microphone: microphone,
            accessibility: accessibility,
            inputMonitoring: inputMonitoring,
            systemAudio: false,
            screenRecording: screenRecording
        )
    }

    static func captureSystemSnapshot() -> Self {
        Self(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: CGPreflightListenEventAccess(),
            screenRecording: CGPreflightScreenCaptureAccess()
        )
    }
}

actor InteractionPermissionMonitor {
    typealias SnapshotReader = @Sendable () -> InteractionPermissionSnapshot
    typealias ChangeHandler = @MainActor @Sendable (InteractionPermissionSnapshot) -> Void

    private let interval: Duration
    private let readSnapshot: SnapshotReader
    private let onChange: ChangeHandler
    private var clientIDs = Set<UUID>()
    private var clientRevision = 0
    private var lastSnapshot: InteractionPermissionSnapshot?
    private var captureGeneration = 0
    private var pollingGeneration = UUID()
    private var pollingTask: Task<Void, Never>?

    init(
        interval: Duration = .seconds(1),
        readSnapshot: @escaping SnapshotReader = {
            InteractionPermissionSnapshot.captureSystemSnapshot()
        },
        onChange: @escaping ChangeHandler
    ) {
        self.interval = interval
        self.readSnapshot = readSnapshot
        self.onChange = onChange
    }

    func updateClients(_ updatedClientIDs: Set<UUID>, revision: Int) {
        guard revision > clientRevision else { return }
        clientRevision = revision
        clientIDs = updatedClientIDs

        if clientIDs.isEmpty {
            pollingGeneration = UUID()
            pollingTask?.cancel()
            pollingTask = nil
        } else if pollingTask == nil {
            let generation = UUID()
            pollingGeneration = generation
            pollingTask = Task { [weak self] in
                await self?.poll(generation: generation)
            }
        }
    }

    func refresh() async {
        await captureAndPublishIfChanged()
    }

    private func poll(generation: UUID) async {
        while !Task.isCancelled,
              generation == pollingGeneration,
              !clientIDs.isEmpty {
            await captureAndPublishIfChanged()
            do {
                try await Task.sleep(for: interval)
            } catch {
                break
            }
        }

        if generation == pollingGeneration {
            pollingTask = nil
        }
    }

    private func captureAndPublishIfChanged() async {
        captureGeneration += 1
        let generation = captureGeneration
        let reader = readSnapshot
        let snapshot = await Task.detached(priority: .utility) {
            reader()
        }.value
        guard generation == captureGeneration else { return }
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        await onChange(snapshot)
    }
}

/// Manual recovery actions are shared by setup, Settings, and recording entry points.
/// Denial never changes navigation or enables a feature on the user's behalf.
enum FeaturePermission: String, Equatable, Sendable {
    case microphone = "Microphone"
    case accessibility = "Accessibility"
    case inputMonitoring = "Input Monitoring"
    case screenRecording = "Screen Recording"

    var privacyPane: String {
        switch self {
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .screenRecording: "Privacy_ScreenCapture"
        }
    }

    static func missingForRecording(
        _ permissions: OnboardingPermissionSnapshot,
        pastesText: Bool,
        isDictationTest: Bool = false
    ) -> Self? {
        if !permissions.microphone { return .microphone }
        // Onboarding tests display their result through a callback and never paste,
        // even before the selected use case is saved to the configuration.
        if pastesText && !isDictationTest && !permissions.accessibility { return .accessibility }
        return nil
    }

    static func missingForScreenHistory(screen: Bool, accessibility: Bool) -> Self? {
        if !screen { return .screenRecording }
        if !accessibility { return .accessibility }
        return nil
    }

    @MainActor private static var requested = Set<FeaturePermission>()

    @MainActor func openSettings() {
        PermissionRestartRecovery.shared.requested(self, wasGranted: isGranted)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(privacyPane)") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor func request() {
        PermissionRestartRecovery.shared.requested(self, wasGranted: isGranted)
        switch self {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else { openSettings() }
        case .accessibility:
            guard Self.requested.insert(self).inserted else { openSettings(); return }
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            if !CGRequestListenEventAccess() { openSettings() }
        case .screenRecording:
            guard Self.requested.insert(self).inserted else { openSettings(); return }
            _ = CGRequestScreenCaptureAccess()
        }
    }
}

/// Single-flight, cancellable permission checks. Returning from Settings can recheck
/// after a failed request without allowing an old completion to update a new screen.
@MainActor @Observable
final class SystemAudioPermissionCheck {
    private(set) var isChecking = false
    private var isRequesting = false
    private var pendingRequest: (@MainActor (Bool) -> Void)?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let read: @Sendable () async -> Bool
    private let requestAccess: @Sendable () async -> Bool

    init(read: @escaping @Sendable () async -> Bool = {
        await Task.detached(priority: .utility) { CoreAudioSystemRecorder.checkSystemAudioPermission() }.value
    }, requestAccess: @escaping @Sendable () async -> Bool = {
        await CoreAudioSystemRecorder.requestSystemAudioAccess()
    }) {
        self.read = read
        self.requestAccess = requestAccess
    }

    func check(request: Bool = false, onResult: @escaping @MainActor (Bool) -> Void) {
        if isChecking {
            // A foreground Grant click must survive an in-flight background read.
            // Coalesce clicks without running two CoreAudio operations at once.
            if request, !isRequesting { pendingRequest = onResult }
            return
        }
        isChecking = true
        isRequesting = request
        let attempt = UUID()
        generation = attempt
        let operation = request ? requestAccess : read
        task = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            var granted = await operation()
            guard let self, !Task.isCancelled, self.generation == attempt else { return }
            var deliver = onResult
            if let pending = self.pendingRequest {
                self.pendingRequest = nil
                self.isRequesting = true
                deliver = pending
                if !granted { granted = await self.requestAccess() }
                guard !Task.isCancelled, self.generation == attempt else { return }
            }
            self.task = nil
            self.isChecking = false
            self.isRequesting = false
            deliver(granted)
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        isChecking = false
        isRequesting = false
        pendingRequest = nil
    }
}
