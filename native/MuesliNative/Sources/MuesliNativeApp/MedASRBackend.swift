@preconcurrency import CoreML
import FluidAudio
import Foundation
import MuesliCore

actor MedASRCoreMLRuntime {
    private let model: MLModel
    private let compiledURL: URL
    private let frontend: MedASRFrontend
    private let gate = InferenceGate()
    let vocabulary: [Int: String]

    private init(model: MLModel, compiledURL: URL, frontend: MedASRFrontend, vocabulary: [Int: String]) {
        self.model = model
        self.compiledURL = compiledURL
        self.frontend = frontend
        self.vocabulary = vocabulary
    }

    deinit { try? FileManager.default.removeItem(at: compiledURL) }

    static func load(directory: URL) async throws -> MedASRCoreMLRuntime {
        try Task.checkCancellation()
        let data = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        guard let config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              config["source"] as? String == "google/medasr",
              config["sample_rate"] as? Int == MedASRModel.sampleRate,
              config["window_samples"] as? Int == MedASRModel.windowSamples,
              config["feature_frames"] as? Int == MedASRModel.featureFrames,
              config["encoded_frames"] as? Int == MedASRModel.encodedFrames,
              config["vocab_size"] as? Int == MedASRModel.vocabularySize,
              config["blank_id"] as? Int == MedASRModel.blankID
        else { throw MedASRError.invalidAssets }
        let strings = try JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: directory.appendingPathComponent("vocab.json")))
        let vocabulary = Dictionary(uniqueKeysWithValues: strings.compactMap { key, value in
            Int(key).map { ($0, value) }
        })
        guard (0..<MedASRModel.vocabularySize).allSatisfy({ vocabulary[$0] != nil }) else {
            throw MedASRError.invalidAssets
        }
        let frontend = try MedASRFrontend(directory: directory)
        let compiled = try await MLModel.compileModel(at: directory.appendingPathComponent(MedASRModel.packageName))
        do {
            try Task.checkCancellation()
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let model = try await MLModel.load(contentsOf: compiled, configuration: configuration)
            try Task.checkCancellation()
            guard model.modelDescription.inputDescriptionsByName["input_features"]?.multiArrayConstraint?.shape.map(\.intValue) == [1,1998,128],
                  model.modelDescription.outputDescriptionsByName["logits"]?.multiArrayConstraint?.shape.map(\.intValue) == [1,497,512]
            else { throw MedASRError.invalidAssets }
            return MedASRCoreMLRuntime(model: model, compiledURL: compiled, frontend: frontend, vocabulary: vocabulary)
        } catch {
            try? FileManager.default.removeItem(at: compiled)
            throw error
        }
    }

    func predict(_ window: MedASRAudioWindows.Window) async throws -> [Int] {
        guard window.samples.count >= MedASRModel.minimumSamples else { return [] }
        try await gate.acquire()
        do {
            let result = try await predictAcquired(window)
            await gate.release()
            return result
        } catch {
            await gate.release()
            throw error
        }
    }

    private func predictAcquired(_ window: MedASRAudioWindows.Window) async throws -> [Int] {
        try Task.checkCancellation()
        let features = try frontend.features(window.samples)
        let input = try MLMultiArray(shape: [1,1998,128], dataType: .float32)
        features.withUnsafeBufferPointer { source in
            input.dataPointer.assumingMemoryBound(to: Float.self).update(from: source.baseAddress!, count: features.count)
        }
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: MedASRModel.featureLength(samples: window.samples.count))
        let provider = try MLDictionaryFeatureProvider(dictionary: ["input_features": input, "feature_lengths": length])
        let prediction = try await model.prediction(from: provider)
        try Task.checkCancellation()
        guard let output = prediction.featureValue(for: "logits")?.multiArrayValue,
              output.dataType == .float32, output.shape.map(\.intValue) == [1,497,512]
        else { throw MedASRError.invalidPrediction }
        let pointer = output.dataPointer.assumingMemoryBound(to: Float.self)
        let strideT = output.strides[1].intValue
        let strideV = output.strides[2].intValue
        return try window.retainedFrames.map { frame in
            var best = 0
            var score: Float = -.infinity
            for token in 0..<MedASRModel.vocabularySize {
                let value = pointer[frame * strideT + token * strideV]
                guard value.isFinite else { throw MedASRError.invalidPrediction }
                if value > score { score = value; best = token }
            }
            return best
        }
    }
}

/// Owns preparation/warmup independently of selection and library downloads.
actor MedASRTranscriber {
    struct Runtime: Sendable {
        let predict: @Sendable (MedASRAudioWindows.Window) async throws -> [Int]
        let vocabulary: [Int: String]
    }
    typealias Loader = @Sendable (((Double, String?) -> Void)?, ModelDownloadProgressHandler?) async throws -> Runtime
    private struct Pending: Sendable {
        let id: UUID
        let task: Task<Runtime, Error>
        var waiters: Set<UUID>
    }
    private var runtime: Runtime?
    private var pending: Pending?
    private var generation: UInt64 = 0
    private let loader: Loader
    private let license: MedASRLicense

    init(loader: Loader? = nil, license: MedASRLicense = .shared) {
        self.license = license
        self.loader = loader ?? { progress, snapshot in
            try await Self.loadRuntime(progress: progress, progressSnapshot: snapshot)
        }
    }

    func prepare(
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws {
        try Task.checkCancellation()
        try license.requireAcceptance()
        if runtime != nil { return }
        let waiter = UUID()
        if pending == nil {
            let loader = self.loader
            let task = Task {
                let loaded = try await loader(progress, progressSnapshot)
                try Task.checkCancellation()
                progressSnapshot?(.preparing(modelID: MedASRModel.id, message: "Preparing MedASR..."))
                progress?(0.98, "Preparing MedASR...")
                _ = try await loaded.predict(.init(samples: [Float](repeating: 0, count: 32_000), leftContext: 0, rightContext: 0))
                try Task.checkCancellation()
                return loaded
            }
            pending = Pending(id: UUID(), task: task, waiters: [])
        }
        pending?.waiters.insert(waiter)
        progressSnapshot?(.preparing(modelID: MedASRModel.id, message: "Preparing MedASR..."))
        let loading = pending!
        let owner = generation
        do {
            let loaded = try await withTaskCancellationHandler {
                try await loading.task.value
            } onCancel: {
                Task { await self.cancel(waiter: waiter, preparation: loading.id) }
            }
            try Task.checkCancellation()
            guard generation == owner else { throw CancellationError() }
            if pending?.id == loading.id {
                runtime = loaded
                pending = nil
            }
            guard runtime != nil else { throw CancellationError() }
            progress?(1, nil)
            progressSnapshot?(.preparing(modelID: MedASRModel.id, message: "Model ready").replacing(phase: .ready, message: "Model ready"))
        } catch {
            cancel(waiter: waiter, preparation: loading.id)
            throw error
        }
    }

    func transcribe(wavURL: URL) async throws -> (text: String, processingTime: Double) {
        guard let runtime else { throw MedASRError.notLoaded }
        let owner = generation
        let started = CFAbsoluteTimeGetCurrent()
        let reader = try DiarizationPCMWindowReader(url: wavURL, seconds: 8)
        var windows = MedASRAudioWindows()
        var decoded = MedASRCTCAccumulator()
        while let input = try reader.next() {
            windows.append(input.samples)
            while let window = windows.next(final: false) {
                decoded.append(try await runtime.predict(window))
                try checkOwner(owner)
            }
        }
        while let window = windows.next(final: true) {
            decoded.append(try await runtime.predict(window))
            try checkOwner(owner)
        }
        return (MedASRFormatting.render(decodeCtcTokenIds(decoded.tokenIDs, vocabulary: runtime.vocabulary)),
                CFAbsoluteTimeGetCurrent() - started)
    }

    func shutdown() {
        generation &+= 1
        pending?.task.cancel()
        pending = nil
        runtime = nil
    }

    private func checkOwner(_ owner: UInt64) throws {
        try Task.checkCancellation()
        guard generation == owner else { throw CancellationError() }
    }

    private func cancel(waiter: UUID, preparation: UUID) {
        guard pending?.id == preparation else { return }
        pending?.waiters.remove(waiter)
        if pending?.waiters.isEmpty == true {
            pending?.task.cancel()
            pending = nil
        }
    }

    private static func loadRuntime(
        progress: ((Double, String?) -> Void)?, progressSnapshot: ModelDownloadProgressHandler?
    ) async throws -> Runtime {
        let loaded = try await ManagedASRModelDownloader.loadValidated(MedASRModel.plan(),
            progress: progress, progressSnapshot: progressSnapshot) { directory in
            progress?(0.95, "Loading MedASR...")
            progressSnapshot?(.preparing(modelID: MedASRModel.id, message: "Loading MedASR..."))
            return try await MedASRCoreMLRuntime.load(directory: directory)
        }
        return Runtime(predict: { try await loaded.predict($0) }, vocabulary: loaded.vocabulary)
    }
}
