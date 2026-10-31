import Foundation
import MuesliCore
import Observation

/// Transient model-library state survives navigation; no model files are read here.
@MainActor
@Observable
final class ModelLibraryState {
    var nemotron35UpdateAvailable = false
    var downloadingModels: Set<String> = []
    var downloadProgress: [String: Double] = [:]
    var downloadMessages: [String: String] = [:]
    var downloadSnapshots: [String: ModelDownloadProgress] = [:]
    var downloadGenerations: [String: UUID] = [:]
    var downloadedModels: Set<String> = []
    var downloadTasks: [String: Task<Void, Never>] = [:]
    var isLiveCaptionModelDownloaded = false
    var isDownloadingLiveCaptionModel = false
    var isCancellingLiveCaptionModelDownload = false
    var liveCaptionDownloadProgress = 0.0
    var liveCaptionDownloadTask: Task<Void, Never>?
    var liveCaptionDownloadGeneration = ModelDownloadGenerationState()
    var downloadingPostProcModels: Set<String> = []
    var downloadProgressPostProc: [String: Double] = [:]
    var downloadedPostProcModels: Set<String> = []
    var downloadTasksPostProc: [String: Task<Void, Never>] = [:]
    var cancellingDownloads: Set<String> = []

    enum DownloadKind { case backend, postProcessor }

    func canStartDownload(_ modelID: String, kind: DownloadKind) -> Bool {
        !cancellingDownloads.contains(modelID)
            && !(kind == .backend ? downloadingModels : downloadingPostProcModels).contains(modelID)
    }

    /// Keep Pause busy until both the transfer and its caller have settled. A remounted
    /// view shares this gate, so a delayed cancellation cannot target a replacement.
    @discardableResult
    func pauseDownload(_ modelID: String, kind: DownloadKind,
                       cancelTransfer: @escaping @MainActor () async -> Void,
                       completion: @escaping @MainActor () -> Void) -> Task<Void, Never>? {
        guard cancellingDownloads.insert(modelID).inserted else { return nil }
        let task = kind == .backend ? downloadTasks[modelID] : downloadTasksPostProc[modelID]
        let generation = UUID()
        downloadGenerations[modelID] = generation
        task?.cancel()
        return Task {
            await cancelTransfer()
            _ = await task?.value
            guard downloadGenerations[modelID] == generation else {
                cancellingDownloads.remove(modelID)
                return
            }
            if kind == .backend {
                downloadingModels.remove(modelID)
                downloadProgress.removeValue(forKey: modelID)
                downloadTasks.removeValue(forKey: modelID)
            } else {
                downloadingPostProcModels.remove(modelID)
                downloadProgressPostProc.removeValue(forKey: modelID)
                downloadTasksPostProc.removeValue(forKey: modelID)
            }
            downloadGenerations.removeValue(forKey: modelID)
            downloadMessages[modelID] = "Paused — select Download to resume"
            if let snapshot = downloadSnapshots[modelID] {
                downloadSnapshots[modelID] = snapshot.replacing(phase: .paused, message: downloadMessages[modelID])
            }
            cancellingDownloads.remove(modelID)
            completion()
        }
    }

    /// Apply only a completed controller scan. Equality guards avoid redraws for no-op refreshes.
    func reconcile(_ snapshot: SettingsModelAvailability) {
        let options = BackendOption.all + Gemma4LiteRTModel.allCases.filter(\.isCleanupOnly).map(BackendOption.gemma4LiteRT)
        let models = Set(options.filter { option in
            snapshot.contains(option) || (option.backend == "gemma4-litert" && snapshot.gemmaIDs.contains(option.model))
        }.map(\.model))
        if downloadedModels != models { downloadedModels = models }
        if downloadedPostProcModels != snapshot.postProcessorIDs {
            downloadedPostProcModels = snapshot.postProcessorIDs
        }
        let liveCaption = snapshot.liveCaptionIDs.contains(MeetingLiveCaptionBackend.parakeetRealtimeEOU.rawValue)
        if isLiveCaptionModelDownloaded != liveCaption { isLiveCaptionModelDownloaded = liveCaption }
    }
}
