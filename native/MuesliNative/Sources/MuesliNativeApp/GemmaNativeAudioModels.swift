import Foundation
import MuesliCore

/// One process-wide default for all Gemma interfaces and managed drafter downloads.
/// Set the diagnostic opt-out before launching the app; resident engines keep this policy.
enum GemmaMTPPolicy {
    static let environmentKey = "MUESLI_GEMMA_MLX_MTP"
    static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines) != "0"
    }
    static func blockSize(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        isEnabled(environment: environment) ? 3 : 1
    }
    /// Drafter download/validation/load failures must not disable the target.
    /// Cancellation still aborts the user's operation, rather than starting inference.
    static func optionalDrafterBlock(requested: Int, load: () async throws -> Void) async throws -> Int {
        try Task.checkCancellation()
        guard requested > 1 else { return 1 }
        do {
            try await load()
            try Task.checkCancellation()
            return requested
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            return 1
        }
    }

}

/// Pinned, previously evaluated full E-series checkpoints; shared download verification contract.
enum GemmaNativeAudioModels {
    static let e2b = ManagedCleanupModel("mlx-community/gemma-4-e2b-it-4bit", "238767527555cb75a05732a84dff5d6ba0dd6809", [
        ("model.safetensors", 3550670554, "038e39a37a7667373d2c3991375446b10c96ae1d717a68674870343db376b76e"),
        ("config.json", 6395, "6397cb6eca41b911d1dcab74e17941351057bd759284052a2331918ff6f9246c"),
        ("generation_config.json", 208, "d4226bbe3117d2d253ba4609720ba82c6c4ce4627a9a6ae05387c78983ac03de"),
        ("model.safetensors.index.json", 218323, "edb157dbf495e23f37377af4a628a9ad13c4ee7937f93ccb36ec9e9a19940f16"),
        ("processor_config.json", 1316, "de3e580aebdc98272d4c4547daffe6525fcbae18a83a0e0bcf0d7444d4ee6f37"),
        ("tokenizer.json", 32169626, "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
        ("tokenizer_config.json", 2740, "080d9e1aff284e2f6043889cd05367966f7c7b80e025fbc0b06745e218158656")
    ])
    static let e4b = ManagedCleanupModel("mlx-community/gemma-4-e4b-it-4bit", "475b9088d29754a3379866cf5aeb6b41acd313c2", [
        ("model.safetensors", 5146800534, "932b8271fc3fe65adcc78b96c10c6268bbfb13e8f67d1358727c0d6ee97e1eff"),
        ("config.json", 6628, "780ccb3a514a5f1ced161d383f948fc22eca9b84b752ca19494f625bd9bad7a6"),
        ("generation_config.json", 208, "d4226bbe3117d2d253ba4609720ba82c6c4ce4627a9a6ae05387c78983ac03de"),
        ("model.safetensors.index.json", 240961, "f8accac59ee7efe87e0c298c854610b262c3cadd477407503147c71209ff0093"),
        ("processor_config.json", 1316, "de3e580aebdc98272d4c4547daffe6525fcbae18a83a0e0bcf0d7444d4ee6f37"),
        ("tokenizer.json", 32169626, "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
        ("tokenizer_config.json", 2740, "080d9e1aff284e2f6043889cd05367966f7c7b80e025fbc0b06745e218158656")
    ])
    static let cleanup = ManagedCleanupModel("Muesli-HQ/gemma4-e2b-muesli-cleanup-v12-mlx-4bit", "29d40bae87983afbc330f39bf6d2b47f38c2215c", [
        ("model.safetensors", 2604122719, "8bdf6a16ac2e0378750a6cd41f01c667c687fc5a37deb9083e0531e0d364d1d5"),
        ("chat_template.jinja", 18810, "241c50d86bdfe5e43307da87f559cd2416aacd67a8de46c15acc0105ef2200b7"),
        ("config.json", 4860, "503ab0b719071041505fa30263822d2f4ae5b199749b47feaa1cd0bccbe6994c"),
        ("generation_config.json", 203, "5439541d3bf0ba9ade7c1122dc14703f85f32a520150351b344b14f48c574cc2"),
        ("model.safetensors.index.json", 95576, "73914239147aea77ab9571f091ce48405493596b2ea61440f35fb78f2c993534"),
        ("tokenizer.json", 32169626, "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
        ("tokenizer_config.json", 2750, "47a25a81fe589682f4e3ca0b580943a70e241c599b463c1fe1954419dc0a4b6f")
    ])
    static func descriptor(for model: Gemma4LiteRTModel) -> ManagedCleanupModel { model.isCleanupOnly ? cleanup : (model == .e4b ? e4b : e2b) }
    static func overrideDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let path = environment["MUESLI_GEMMA_MLX_MODEL_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    static func directory(for model: Gemma4LiteRTModel, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        overrideDirectory(environment: environment) ?? artifactDirectory(descriptor(for: model))
    }
    static func artifactDirectory(_ artifact: ManagedCleanupModel, fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".cache/muesli/models/mlx-evaluation/" + artifact.revision)
    }
    static func isAvailable(_ model: Gemma4LiteRTModel, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        descriptor(for: model).isPresent(at: directory(for: model, environment: environment))
    }
    static func ensureDownloaded(_ model: Gemma4LiteRTModel, progress: ((Double, String?) -> Void)? = nil,
                                 progressSnapshot: ModelDownloadProgressHandler? = nil) async throws -> URL {
        let target = descriptor(for: model)
        let destination = directory(for: model)
        if overrideDirectory() != nil {
            try target.validate(modelURL: destination.appendingPathComponent(target.modelFilename))
        } else {
            try await ModelDownloadCoordinator.shared.download(target.manifest(id: model.repoID), to: destination) { snapshot in
                progress?(snapshot.fractionCompleted ?? 0, "Downloading \(model.label)")
                progressSnapshot?(snapshot)
            }
        }
        let block = try await GemmaMTPPolicy.optionalDrafterBlock(requested: GemmaMTPPolicy.blockSize()) {
            let assistant = drafter(for: model)
            try await ModelDownloadCoordinator.shared.download(assistant.manifest(id: assistant.repoID + "-drafter"), to: artifactDirectory(assistant), cancelWhenUnobserved: true) { snapshot in
                progress?(snapshot.fractionCompleted ?? 0, "Downloading \(model.label) MTP weights")
                progressSnapshot?(snapshot)
            }
        }
        if block == 1 && GemmaMTPPolicy.isEnabled() {
            Gemma4LiteRTLogging.profile("native_audio drafter_download_unavailable model=\(model.label) fallback=target_only")
        }
        return destination.appendingPathComponent(target.modelFilename)
    }
    // Assistant weights are additional speculative heads; target weights stay unchanged.
    static let e2bDrafter = ManagedCleanupModel("mlx-community/gemma-4-E2B-it-assistant-bf16", "a7770799b560135ebdbfae8b7f468947415003bc", [
        ("model.safetensors", 157565344, "93682eb1c97639d18f007704dc880bd74cbe530adaf7b1bb561213863fdad2a6"),
        ("config.json", 2315, "7f42f559a6a69ffaeaf6b61a1ece3a562a2ed5ad00b8d30f16917ba5ab1bcbe9"),
        ("generation_config.json", 307, "8e58004dc0e2407b63410b190bb8470efbdcfeb71533f1770e09c20abe193a6f"),
        ("tokenizer.json", 32169440, "75a6583c1a418e2bbd79c60d95d28e0f5bf549ad3f2990b5bdb5238c6c2bf70c"),
        ("tokenizer_config.json", 822, "089594a3924fcfd4cb1c596a7906fbf476193519e5198f780912eed02b177e42")
    ])
    static let e4bDrafter = ManagedCleanupModel("mlx-community/gemma-4-E4B-it-assistant-bf16", "844e008e06ef5562bdb89428d851d0634d119dcd", [
        ("model.safetensors", 159138208, "12875062fc25c51e8fa9b62abd2de7ad48b7d63f8559d5d604fbd5a3d6bcff16"),
        ("config.json", 2315, "13cdf5418e5a89cf951717a953cd11cef4e5c2743c4767e9e5dd72802954f822"),
        ("generation_config.json", 307, "8e58004dc0e2407b63410b190bb8470efbdcfeb71533f1770e09c20abe193a6f"),
        ("tokenizer.json", 32169440, "75a6583c1a418e2bbd79c60d95d28e0f5bf549ad3f2990b5bdb5238c6c2bf70c"),
        ("tokenizer_config.json", 822, "089594a3924fcfd4cb1c596a7906fbf476193519e5198f780912eed02b177e42")
    ])
    static func drafter(for model: Gemma4LiteRTModel) -> ManagedCleanupModel { model == .e4b ? e4bDrafter : e2bDrafter }

}

/// One ordered preparation sequence; identical models share a resident engine.
struct GemmaPreparationPlan: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let model: Gemma4LiteRTModel
        var audio: Bool
        var text: Bool
        var required: Bool
    }
    let entries: [Entry]
    /// A local non-Gemma ASR dependency used by Quill, prepared by the coordinator.
    let additionalPreparationKey: String?
    var isEmpty: Bool { entries.isEmpty && additionalPreparationKey == nil }
    var key: String { (additionalPreparationKey.map { $0 + "|" } ?? "") + entries.map { "\($0.model.rawValue):\($0.audio):\($0.text):\($0.required)" }.joined(separator: "|") }
    init(dictation: Gemma4LiteRTModel?, cleanup: Gemma4LiteRTModel?, quill: Gemma4LiteRTModel?, requireQuill: Bool = false, additionalPreparationKey: String? = nil) {
        self.additionalPreparationKey = additionalPreparationKey
        var result: [Entry] = []
        func add(_ model: Gemma4LiteRTModel?, audio: Bool, text: Bool, required: Bool) {
            guard let model else { return }
            if let i = result.firstIndex(where: { $0.model == model }) {
                result[i].audio = result[i].audio || audio
                result[i].text = result[i].text || text
                result[i].required = result[i].required || required
            } else { result.append(Entry(model: model, audio: audio, text: text, required: required)) }
        }
        add(dictation, audio: true, text: false, required: true)
        add(cleanup, audio: false, text: true, required: false)
        add(quill, audio: true, text: true, required: requireQuill)
        entries = result
    }
    /// Optional feature failures do not prevent ordinary dictation. Each feature
    /// still validates its artifacts again before inference; cancellation always propagates.
    func prepare(optionalModelAvailable: (Gemma4LiteRTModel) -> Bool = { _ in true },
                 using operation: (Entry) async throws -> Void,
                 optionalFailure: (Entry, Error) -> Void) async throws {
        for entry in entries {
            try Task.checkCancellation()
            // Perform filesystem work in preparation, never in the hotkey's plan construction.
            if !entry.required && !optionalModelAvailable(entry.model) { continue }
            do { try await operation(entry) }
            catch {
                try Task.checkCancellation()
                if entry.required || error is CancellationError { throw error }
                optionalFailure(entry, error)
            }
        }
    }
}

/// A rejected gesture is never queued: readiness only admits a NEW recording gesture.
@MainActor
final class GemmaRecordingPreparationGate {
    private(set) var readyKey: String?
    private var readyKeys: Set<String> = []
    private(set) var pendingKey: String?
    private var generation = UUID()
    private var task: Task<Void, Never>?

    private func cancelPending() {
        generation = UUID()
        task?.cancel(); task = nil
        pendingKey = nil
    }

    func invalidate() {
        cancelPending()
        readyKey = nil
        readyKeys.removeAll()
    }

    func request(_ plan: GemmaPreparationPlan,
                 prepare: @escaping @MainActor () async throws -> Void,
                 ready: @escaping @MainActor () -> Void,
                 failed: @escaping @MainActor (Error) -> Void) -> Bool {
        if plan.isEmpty { cancelPending(); readyKey = nil; return true }
        if readyKeys.contains(plan.key) { cancelPending(); readyKey = plan.key; return true }
        if pendingKey == plan.key { return false }
        cancelPending()
        readyKey = nil
        let token = generation
        pendingKey = plan.key
        task = Task { [weak self] in
            do {
                try await prepare()
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.readyKeys.insert(plan.key)
                self.readyKey = plan.key; self.pendingKey = nil; self.task = nil
                ready()
            } catch {
                guard let self, self.generation == token else { return }
                self.pendingKey = nil; self.task = nil
                failed(error)
            }
        }
        return false
    }

    func waitForPreparation() async { await task?.value }
}
