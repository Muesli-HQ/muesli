import Foundation
import FluidAudio
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("Orukeet model installation")
struct OrukeetModelStoreTests {
    private func manifest(filename: String = "orukeet-r3-coreml-baseline.zip",
                          bytes: Int = OrukeetModelStore.archiveBytes,
                          sha256: String = OrukeetModelStore.archiveSHA256) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["archives": ["baseline": [
            "filename": filename, "bytes": bytes, "sha256": sha256,
        ]]])
    }

    @Test("Orukeet is optional and uses its own managed Hugging Face installation")
    func catalogAndDownloadIdentity() {
        #expect(BackendOption.experimental.contains(.orukeet))
        #expect(!BackendOption.onboarding.contains(.orukeet))
        #expect(!BackendOption.orukeet.recommended)
        #expect(BackendOption.resolve(backend: "fluidaudio", model: "oruk/orukeet") == .orukeet)
        let plan = OrukeetModelStore.plan
        #expect(plan.modelID == "oruk/orukeet")
        #expect(plan.repository == "oruk/orukeet")
        #expect(plan.revision == OrukeetModelStore.revision)
        #expect(plan.mirror == nil)
        #expect(plan.selections[0].includedPaths == ["manifest.json", "orukeet-r3-coreml-baseline.zip"])
    }

    @Test("Pinned integrity manifest rejects changed metadata")
    func manifestIntegrity() throws {
        _ = try OrukeetModelStore.validateManifest(manifest())
        #expect(throws: (any Error).self) { try OrukeetModelStore.validateManifest(manifest(filename: "other.zip")) }
        #expect(throws: (any Error).self) { try OrukeetModelStore.validateManifest(manifest(bytes: 1)) }
        #expect(throws: (any Error).self) { try OrukeetModelStore.validateManifest(manifest(sha256: "incorrect")) }
    }

    @Test("Incomplete and corrupt installations do not replace an existing cache")
    func failedInstallation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("previous")
        try Data("previous".utf8).write(to: marker)
        try OrukeetModelStore.revision.write(to: destination.appendingPathComponent(".revision"), atomically: true, encoding: .utf8)
        #expect(!OrukeetModelStore.installed(at: destination))
        #expect(throws: (any Error).self) { try OrukeetModelStore.load(from: destination) }
        let archive = root.appendingPathComponent("corrupt.zip")
        try Data("corrupt".utf8).write(to: archive)
        #expect(throws: (any Error).self) { try OrukeetModelStore.installArchive(at: archive, to: destination) }
        #expect(throws: (any Error).self) {
            try OrukeetModelStore.commitInstallation(from: root.appendingPathComponent("missing"), to: destination)
        }
        #expect(try Data(contentsOf: marker) == Data("previous".utf8))
    }

    @Test("Size-valid corrupt downloads lose their completion marker so Retry reacquires them", arguments: [true, false])
    func corruptDownloadCanRetry(corruptManifest: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloaded = root.appendingPathComponent("download")
        try FileManager.default.createDirectory(at: downloaded, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = root.appendingPathComponent("compiled")
        try Data("working compiled model".utf8).write(to: previous)
        let metadata = try manifest(sha256: corruptManifest ? String(repeating: "0", count: 64) : OrukeetModelStore.archiveSHA256)
        try metadata.write(to: downloaded.appendingPathComponent("manifest.json"))
        let archive = downloaded.appendingPathComponent("orukeet-r3-coreml-baseline.zip")
        #expect(FileManager.default.createFile(atPath: archive.path, contents: nil))
        let handle = try FileHandle(forWritingTo: archive)
        try handle.truncate(atOffset: UInt64(OrukeetModelStore.archiveBytes))
        try handle.close()
        let original = OrukeetModelStore.plan
        let plan = ManagedASRModelPlan(modelID: original.modelID, repository: original.repository,
                                      revision: original.revision, cacheDirectory: downloaded,
                                      selections: original.selections,
                                      requiredArtifactAlternatives: original.requiredArtifactAlternatives)
        try plan.recordSuccessfulInstallation(ModelDownloadManifest(id: plan.modelID, version: plan.revision, files: [
            ModelDownloadFile(relativePath: "manifest.json", remoteURL: archive, expectedByteCount: Int64(metadata.count)),
            ModelDownloadFile(relativePath: archive.lastPathComponent, remoteURL: archive,
                              expectedByteCount: Int64(OrukeetModelStore.archiveBytes)),
        ]))
        #expect(plan.isComplete())
        #expect(throws: (any Error).self) { try OrukeetModelStore.validatedArchive(in: downloaded) }
        #expect(!plan.isAvailableLocally())
        #expect(!FileManager.default.fileExists(atPath: downloaded.path))
        #expect(try Data(contentsOf: previous) == Data("working compiled model".utf8))
    }

    @Test("Atomic replacement publishes the new directory without stranded backups")
    func atomicReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("compiled")
        let replacement = root.appendingPathComponent("staged")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("old".utf8).write(to: destination.appendingPathComponent("weights"))
        try Data("new".utf8).write(to: replacement.appendingPathComponent("weights"))
        try OrukeetModelStore.commitInstallation(from: replacement, to: destination)
        #expect(try Data(contentsOf: destination.appendingPathComponent("weights")) == Data("new".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["compiled"])
    }

    @Test("A canceled caller detaches while another caller can finish shared installation", .timeLimit(.minutes(1)))
    func callerCancellationDoesNotAbortInstallation() async throws {
        let installer = OrukeetInstallation()
        let started = OrukeetInstallationGate()
        let finish = OrukeetInstallationGate()
        let cancellation = OrukeetInstallationGate()
        let first = Task {
            try await installer.run { _, _ in
                await started.open()
                try await withTaskCancellationHandler {
                    await finish.wait()
                    try Task.checkCancellation()
                } onCancel: {
                    Task { await cancellation.open(); await finish.open() }
                }
            }
        }
        await started.wait()
        let second = Task { try await installer.run { _, _ in} }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await cancellation.isOpen == false)
        await finish.open()
        try await second.value
    }

    @Test("Explicit cancellation waits for cleanup and allows a fresh retry", .timeLimit(.minutes(1)))
    func explicitCancellationAndRetry() async throws {
        let installer = OrukeetInstallation()
        let started = OrukeetInstallationGate()
        let finish = OrukeetInstallationGate()
        let first = Task {
            try await installer.run { _, _ in
                await started.open()
                try await withTaskCancellationHandler {
                    await finish.wait()
                    try Task.checkCancellation()
                } onCancel: {
                    Task { await finish.open() }
                }
            }
        }
        await started.wait()
        await installer.cancelAndWait()
        await #expect(throws: CancellationError.self) { try await first.value }
        let retried = OrukeetInstallationGate()
        try await installer.run { _, _ in await retried.open() }
        #expect(await retried.isOpen)
    }

    @Test("Joiners receive current and future progress, and canceled callers stop observing", .timeLimit(.minutes(1)))
    func sharedProgressSubscribers() async throws {
        let installer = OrukeetInstallation()
        let owner = OrukeetProgressRecorder(), joiner = OrukeetProgressRecorder()
        let ownerScalar = OrukeetInstallationGate(), ownerSnapshot = OrukeetInstallationGate()
        let joinedScalar = OrukeetInstallationGate(), joinedSnapshot = OrukeetInstallationGate()
        let next = OrukeetInstallationGate(), finish = OrukeetInstallationGate()
        let compiledScalar = OrukeetInstallationGate(), compiledSnapshot = OrukeetInstallationGate()
        let first = Task {
            try await installer.run(progress: { fraction, _ in
                owner.record(fraction)
                Task { await ownerScalar.open() }
            }, progressSnapshot: { snapshot in
                owner.record(snapshot.message)
                Task { await ownerSnapshot.open() }
            }) { report, snapshot in
                report(0.2, "Downloading")
                snapshot(.preparing(modelID: OrukeetModelStore.modelID, message: "Downloading"))
                await next.wait()
                report(0.7, "Compiling")
                snapshot(.preparing(modelID: OrukeetModelStore.modelID, message: "Compiling"))
                await finish.wait()
            }
        }
        await ownerScalar.wait()
        await ownerSnapshot.wait()
        let second = Task {
            try await installer.run(progress: { fraction, _ in
                joiner.record(fraction)
                Task {
                    if fraction == 0.2 { await joinedScalar.open() }
                    else { await compiledScalar.open() }
                }
            }, progressSnapshot: { snapshot in
                joiner.record(snapshot.message)
                Task {
                    if snapshot.message == "Downloading" { await joinedSnapshot.open() }
                    else { await compiledSnapshot.open() }
                }
            }) { _, _ in
                Issue.record("A joining caller must not start another installation")
            }
        }
        await joinedScalar.wait()
        await joinedSnapshot.wait()
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await next.open()
        await compiledScalar.wait()
        await compiledSnapshot.wait()
        #expect(owner.fractions == [0.2])
        #expect(owner.messages == ["Downloading"])
        #expect(joiner.fractions == [0.2, 0.7])
        #expect(joiner.messages == ["Downloading", "Compiling"])
        await finish.open()
        try await second.value
    }

    @Test("Retry waits for an older UI cancellation, including repeated Cancel", .timeLimit(.minutes(1)), arguments: [false, true])
    func retryWaitsForCancellation(cancelRetry: Bool) async throws {
        let installer = OrukeetInstallation()
        var barrier = OrukeetCancellationBarrier()
        let managedCancelStarted = OrukeetInstallationGate(), managedCancelReturn = OrukeetInstallationGate()
        let cleanupFinished = OrukeetInstallationGate(), retryWaiting = OrukeetInstallationGate()
        let replacementStarted = OrukeetInstallationGate(), secondCancelFinished = OrukeetInstallationGate()
        // The old install has finished, but the UI cancellation is still awaiting
        // the managed downloader before it cancels the Orukeet installation.
        barrier.enqueue {
            await managedCancelStarted.open()
            await managedCancelReturn.wait()
            await installer.cancelAndWait()
            await cleanupFinished.open()
        }
        await managedCancelStarted.wait()
        let pending = barrier.pending
        let retry = Task {
            await retryWaiting.open()
            await pending?.value
            try Task.checkCancellation()
            try await installer.run { _, _ in await replacementStarted.open() }
        }
        await retryWaiting.wait()
        #expect(await replacementStarted.isOpen == false)
        if cancelRetry {
            retry.cancel()
            barrier.enqueue {
                #expect(await cleanupFinished.isOpen)
                await installer.cancelAndWait()
                await secondCancelFinished.open()
            }
            let latest = barrier.pending
            let replacement = Task {
                await latest?.value
                try Task.checkCancellation()
                #expect(await secondCancelFinished.isOpen)
                try await installer.run { _, _ in await replacementStarted.open() }
            }
            #expect(await secondCancelFinished.isOpen == false)
            await managedCancelReturn.open()
            await #expect(throws: CancellationError.self) { try await retry.value }
            try await replacement.value
        } else {
            await managedCancelReturn.open()
            try await retry.value
        }
        #expect(await cleanupFinished.isOpen)
        #expect(await replacementStarted.isOpen)
    }

    @Test("Persisted readiness and manifest metadata reload, and disappear after removal")
    func persistedCacheLifecycle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(!OrukeetModelStore.installed(at: root))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = root.appendingPathComponent("manifest.json")
        try manifest().write(to: metadata)
        let reloaded = try OrukeetModelStore.validateManifest(Data(contentsOf: metadata))
        #expect(reloaded.bytes == OrukeetModelStore.archiveBytes)
        #expect(reloaded.sha256 == OrukeetModelStore.archiveSHA256)
        for component in OrukeetModelStore.components {
            let compiled = root.appendingPathComponent(component + ".mlmodelc")
            try FileManager.default.createDirectory(at: compiled.appendingPathComponent("weights"), withIntermediateDirectories: true)
            try Data([1]).write(to: compiled.appendingPathComponent("coremldata.bin"))
            try Data([1]).write(to: compiled.appendingPathComponent("weights/weight.bin"))
        }
        try Data("{}".utf8).write(to: root.appendingPathComponent("parakeet_vocab.json"))
        let revision = root.appendingPathComponent(".revision")
        try OrukeetModelStore.revision.write(to: revision, atomically: true, encoding: .utf8)
        #expect(OrukeetModelStore.installed(at: root))
        #expect(OrukeetModelStore.installed(at: URL(fileURLWithPath: root.path)))
        try "wrong-revision".write(to: revision, atomically: true, encoding: .utf8)
        #expect(!OrukeetModelStore.installed(at: root))
        try OrukeetModelStore.revision.write(to: revision, atomically: true, encoding: .utf8)
        #expect(OrukeetModelStore.installed(at: root))
        try FileManager.default.removeItem(at: root)
        #expect(!OrukeetModelStore.installed(at: root))
    }

    @Test("Older asynchronous loads cannot overwrite a newer backend", arguments: [true, false])
    func staleModelLoadIsRejected(orukeetFirst: Bool) async throws {
        let started = OrukeetInstallationGate()
        let finish = OrukeetInstallationGate()
        let old: FluidAudioTranscriber.ModelSelection = orukeetFirst ? .orukeet : .parakeet(.v3)
        let transcriber = FluidAudioTranscriber(managerLoader: { selection, _, _ in
            if selection == old { await started.open(); await finish.wait() }
            return AsrManager(config: .default)
        })
        let first = Task {
            if orukeetFirst { try await transcriber.loadOrukeet() }
            else { try await transcriber.loadModels(version: .v3) }
        }
        await started.wait()
        if orukeetFirst { try await transcriber.loadModels(version: .v3) }
        else { try await transcriber.loadOrukeet() }
        await finish.open()
        await #expect(throws: CancellationError.self) { try await first.value }
    }

    @Test("Selecting an already loaded model invalidates an older pending load")
    func cachedSelectionRejectsPendingLoad() async throws {
        let started = OrukeetInstallationGate()
        let finish = OrukeetInstallationGate()
        let transcriber = FluidAudioTranscriber(managerLoader: { selection, _, _ in
            if selection == .orukeet { await started.open(); await finish.wait() }
            return AsrManager(config: .default)
        })
        try await transcriber.loadModels(version: .v3)
        let first = Task { try await transcriber.loadOrukeet() }
        await started.wait()
        try await transcriber.loadModels(version: .v3)
        await finish.open()
        await #expect(throws: CancellationError.self) { try await first.value }
    }

    @Test("Unloading an in-progress model prevents it from publishing", arguments: [true, false])
    func unloadingPendingModel(orukeet: Bool) async throws {
        let started = OrukeetInstallationGate()
        let finish = OrukeetInstallationGate()
        let transcriber = FluidAudioTranscriber(managerLoader: { _, _, _ in
            await started.open()
            await finish.wait()
            return AsrManager(config: .default)
        })
        let first = Task {
            if orukeet { try await transcriber.loadOrukeet() }
            else { try await transcriber.loadModels(version: .v3) }
        }
        await started.wait()
        if orukeet { await transcriber.shutdownOrukeet() }
        else { await transcriber.shutdown(ifLoadedVersion: .v3) }
        await finish.open()
        await #expect(throws: CancellationError.self) { try await first.value }
    }

    // Explicitly opt in: this test downloads the preview once and runs the real app backend.
    @Test("Repeated real-model transcription and cached reload", .enabled(if: ProcessInfo.processInfo.environment["ORUKEET_AUDIO_DIR"] != nil))
    func runtimeSmoke() async throws {
        let audio = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORUKEET_AUDIO_DIR"]!)
        let transcriber = FluidAudioTranscriber()
        try await transcriber.loadOrukeet()
        #expect(OrukeetModelStore.isInstalled)
        var transcripts: [String: String] = [:]
        for round in 0..<2 {
            for name in ["en", "de", "fr", "silence"] {
                let start = Date()
                let result = try await transcriber.transcribe(wavURL: audio.appendingPathComponent(name + ".wav"))
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if name == "silence" { #expect(text.isEmpty) } else { #expect(!text.isEmpty) }
                if let previous = transcripts[name] { #expect(text == previous) }
                transcripts[name] = text
                print("ORUKEET_SMOKE round=\(round) clip=\(name) seconds=\(Date().timeIntervalSince(start)) text=\(text)")
            }
            await transcriber.shutdownOrukeet()
            try await transcriber.loadOrukeet()
        }
        await transcriber.shutdownOrukeet()
    }
}

private actor OrukeetInstallationGate {
    private(set) var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private final class OrukeetProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedFractions: [Double] = []
    private var recordedMessages: [String?] = []

    func record(_ fraction: Double) {
        lock.lock()
        defer { lock.unlock() }
        recordedFractions.append(fraction)
    }

    func record(_ message: String?) {
        lock.lock()
        defer { lock.unlock() }
        recordedMessages.append(message)
    }

    var fractions: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return recordedFractions
    }

    var messages: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return recordedMessages
    }
}
