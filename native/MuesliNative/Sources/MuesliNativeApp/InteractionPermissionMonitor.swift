import AppKit
import AVFoundation
import Foundation

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
        let reader = readSnapshot
        let snapshot = await Task.detached(priority: .utility) {
            reader()
        }.value
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        await onChange(snapshot)
    }
}
