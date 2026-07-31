import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Diarizer runtime policy")
struct DiarizerRuntimePolicyTests {
    @Test("M1 family on macOS 15.1 avoids GPU compute")
    func m1OnMacOS151UsesCPUAndNeuralEngine() {
        for cpuBrand in ["Apple M1", "Apple M1 Pro", "Apple M1 Max", "Apple M1 Ultra"] {
            let policy = DiarizerRuntimePolicy.resolve(
                for: environment(cpuBrand: cpuBrand, os: (15, 1, 1))
            )

            #expect(policy.computePolicy == .cpuAndNeuralEngine)
            #expect(policy.compatibilityRule == DiarizerRuntimePolicy.m1MacOS151CompatibilityRule)
        }
    }

    @Test("hardware model identifies M1 when CPU brand is unavailable")
    func hardwareModelFallback() {
        let policy = DiarizerRuntimePolicy.resolve(
            for: environment(
                cpuBrand: nil,
                hardwareModel: "MacBookPro17,1",
                os: (15, 1, 1)
            )
        )

        #expect(policy.computePolicy == .cpuAndNeuralEngine)
    }

    @Test("M1 on newer macOS keeps the default policy")
    func m1OnNewerMacOSUsesDefault() {
        let policy = DiarizerRuntimePolicy.resolve(
            for: environment(cpuBrand: "Apple M1", os: (15, 2, 0))
        )

        #expect(policy.computePolicy == .all)
        #expect(policy.compatibilityRule == DiarizerRuntimePolicy.defaultCompatibilityRule)
    }

    @Test("newer Apple silicon on macOS 15.1 keeps the default policy")
    func m2OnMacOS151UsesDefault() {
        let policy = DiarizerRuntimePolicy.resolve(
            for: environment(cpuBrand: "Apple M2", os: (15, 1, 1))
        )

        #expect(policy.computePolicy == .all)
    }

    @Test("cache state distinguishes absent, partial, and complete models")
    func cacheState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiarizerRuntimePolicyTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let requiredModels: Set<String> = ["segmentation.mlmodelc", "embedding.mlmodelc"]

        #expect(
            DiarizerModelCacheState.resolve(
                directory: directory,
                requiredModelNames: requiredModels
            ) == .absent
        )

        try Data().write(to: directory.appendingPathComponent("segmentation.mlmodelc"))
        #expect(
            DiarizerModelCacheState.resolve(
                directory: directory,
                requiredModelNames: requiredModels
            ) == .partial
        )

        try Data().write(to: directory.appendingPathComponent("embedding.mlmodelc"))
        #expect(
            DiarizerModelCacheState.resolve(
                directory: directory,
                requiredModelNames: requiredModels
            ) == .complete
        )
    }

    private func environment(
        cpuBrand: String?,
        hardwareModel: String? = nil,
        os: (Int, Int, Int)
    ) -> DiarizerRuntimeEnvironment {
        DiarizerRuntimeEnvironment(
            cpuBrand: cpuBrand,
            hardwareModel: hardwareModel,
            operatingSystemVersion: OperatingSystemVersion(
                majorVersion: os.0,
                minorVersion: os.1,
                patchVersion: os.2
            )
        )
    }
}

@Suite("Diarizer preload diagnostics")
struct DiarizerPreloadDiagnosticsTests {
    private final class SignalRecorder {
        var events: [(String, [String: String])] = []

        func record(_ event: String, parameters: [String: String]) {
            events.append((event, parameters))
        }
    }

    @Test("uncleared attempt is reported as interrupted on next launch")
    func interruptedAttempt() throws {
        let suiteName = "DiarizerPreloadDiagnosticsTests.interrupted.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = SignalRecorder()
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let context = makeContext()

        DiarizerPreloadDiagnostics(
            defaults: defaults,
            now: { startedAt },
            signalSink: recorder.record
        ).begin(context)
        DiarizerPreloadDiagnostics(
            defaults: defaults,
            now: { startedAt.addingTimeInterval(8) },
            signalSink: recorder.record
        ).reportInterruptedAttemptIfNeeded()

        #expect(recorder.events.map(\.0) == [
            "diarizer.preload.started",
            "diarizer.preload.interrupted",
        ])
        #expect(recorder.events.last?.1["duration_bucket"] == "5_to_15s")
        #expect(recorder.events.last?.1["compute_policy"] == "cpu_and_neural_engine")

        DiarizerPreloadDiagnostics(
            defaults: defaults,
            signalSink: recorder.record
        ).reportInterruptedAttemptIfNeeded()
        #expect(recorder.events.count == 2)
    }

    @Test("successful load clears the interruption marker")
    func readyClearsMarker() throws {
        let suiteName = "DiarizerPreloadDiagnosticsTests.ready.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = SignalRecorder()
        let startedAt = Date(timeIntervalSince1970: 2_000)
        let diagnostics = DiarizerPreloadDiagnostics(
            defaults: defaults,
            now: { startedAt.addingTimeInterval(2) },
            signalSink: recorder.record
        )
        let context = makeContext()

        diagnostics.begin(context)
        diagnostics.ready(context, startedAt: startedAt)
        diagnostics.reportInterruptedAttemptIfNeeded()

        #expect(recorder.events.map(\.0) == [
            "diarizer.preload.started",
            "diarizer.preload.ready",
        ])
        #expect(recorder.events.last?.1["duration_bucket"] == "1_to_5s")
    }

    @Test("corrupt pending attempt is discarded without a signal")
    func corruptPendingAttempt() throws {
        let suiteName = "DiarizerPreloadDiagnosticsTests.corrupt.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = SignalRecorder()
        defaults.set(
            Data("not json".utf8),
            forKey: DiarizerPreloadDiagnostics.pendingAttemptKey
        )

        DiarizerPreloadDiagnostics(defaults: defaults, signalSink: recorder.record)
            .reportInterruptedAttemptIfNeeded()

        #expect(recorder.events.isEmpty)
        #expect(defaults.data(forKey: DiarizerPreloadDiagnostics.pendingAttemptKey) == nil)
    }

    @Test("failure telemetry is categorical and excludes raw error text")
    func failureIsCategorical() throws {
        let suiteName = "DiarizerPreloadDiagnosticsTests.failure.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = SignalRecorder()
        let diagnostics = DiarizerPreloadDiagnostics(
            defaults: defaults,
            signalSink: recorder.record
        )
        let context = makeContext()
        let startedAt = diagnostics.begin(context)

        diagnostics.failed(
            context,
            startedAt: startedAt,
            error: URLError(.notConnectedToInternet)
        )

        let parameters = try #require(recorder.events.last?.1)
        #expect(parameters["failure_category"] == "network")
        #expect(!parameters.keys.contains("error"))
        #expect(!parameters.values.contains { $0.localizedCaseInsensitiveContains("internet") })
    }

    @Test("base telemetry uses an explicit privacy-safe allowlist")
    func telemetryAllowlist() {
        let parameters = makeContext().telemetryParameters

        #expect(Set(parameters.keys) == [
            "schema_version",
            "trigger",
            "compute_policy",
            "compatibility_rule",
            "cache_state",
            "model_set",
            "fluid_audio_version",
        ])
    }

    @Test(
        "duration buckets are stable",
        arguments: [
            (-30.0, "under_1s"),
            (0.5, "under_1s"),
            (1.0, "1_to_5s"),
            (5.0, "5_to_15s"),
            (15.0, "15_to_60s"),
            (60.0, "60s_or_more"),
        ]
    )
    func durationBuckets(argument: (TimeInterval, String)) {
        #expect(DiarizerPreloadDiagnostics.durationBucket(argument.0) == argument.1)
    }

    @Test("only Cocoa file errors are classified as filesystem failures")
    func cocoaFailureCategories() {
        let fileError = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        let validationError = NSError(domain: NSCocoaErrorDomain, code: NSKeyValueValidationError)

        #expect(DiarizerPreloadDiagnostics.failureCategory(for: fileError) == "filesystem")
        #expect(DiarizerPreloadDiagnostics.failureCategory(for: validationError) == "other")
        #expect(
            DiarizerPreloadDiagnostics.failureCategory(
                for: DiarizerPreloadFailure.operationTimedOut
            ) == "timeout"
        )
    }

    private func makeContext() -> DiarizerPreloadContext {
        DiarizerPreloadContext(
            trigger: .appLaunch,
            policy: DiarizerRuntimePolicy(
                computePolicy: .cpuAndNeuralEngine,
                compatibilityRule: DiarizerRuntimePolicy.m1MacOS151CompatibilityRule
            ),
            cacheState: .complete
        )
    }
}

@Suite("Diarizer preload coordination")
struct DiarizerPreloadCoordinationTests {
    private enum TestLoadError: Error {
        case failed
    }

    private actor BlockingLoader {
        private(set) var attempts = 0
        private var continuation: CheckedContinuation<Void, Never>?
        private var isReleased = false

        func waitUntilReleased() async {
            attempts += 1
            guard !isReleased else { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func release() {
            isReleased = true
            let continuation = continuation
            self.continuation = nil
            continuation?.resume()
        }
    }

    private final class LockedSignalRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storedEvents: [(String, [String: String])] = []

        func record(_ event: String, parameters: [String: String]) {
            lock.lock()
            storedEvents.append((event, parameters))
            lock.unlock()
        }

        func events() -> [(String, [String: String])] {
            lock.lock()
            defer { lock.unlock() }
            return storedEvents
        }
    }

    @Test("cancelled joiner returns while the shared preload continues")
    func cancelledJoinerReturnsPromptly() async throws {
        let loader = BlockingLoader()
        let diagnostics = try makeDiagnostics(suffix: "cancelled-joiner")
        let coordinator = TranscriptionCoordinator(
            diarizerModelLoader: { _ in
                await loader.waitUntilReleased()
                throw TestLoadError.failed
            },
            diarizerDiagnostics: diagnostics.value
        )

        let initiatingCaller = Task {
            await coordinator.preloadDiarizer(trigger: .appLaunch, waitTimeout: .seconds(5))
        }
        #expect(await waitUntil {
            let state = await coordinator.diarizerPreloadStateForTesting()
            return await loader.attempts == 1 && state.waiterCount == 1
        })

        let joinedCaller = Task {
            await coordinator.preloadDiarizer(trigger: .meetingStart, waitTimeout: .seconds(5))
        }
        #expect(await waitUntil {
            await coordinator.diarizerPreloadStateForTesting().waiterCount == 2
        })

        joinedCaller.cancel()
        let cancellationObserved = await waitUntil {
            let state = await coordinator.diarizerPreloadStateForTesting()
            return state.isActive && state.waiterCount == 1
        }
        #expect(cancellationObserved)

        if !cancellationObserved {
            await loader.release()
        }
        await joinedCaller.value
        #expect(await loader.attempts == 1)

        await loader.release()
        await initiatingCaller.value
        diagnostics.cleanup()
    }

    @Test("shared preload has an operation deadline")
    func sharedPreloadHasDeadline() async throws {
        let loader = BlockingLoader()
        let diagnostics = try makeDiagnostics(suffix: "operation-timeout")
        let coordinator = TranscriptionCoordinator(
            diarizerModelLoader: { _ in
                await loader.waitUntilReleased()
                throw TestLoadError.failed
            },
            diarizerLoadOperationTimeout: .milliseconds(30),
            diarizerDiagnostics: diagnostics.value
        )

        await coordinator.preloadDiarizer(trigger: .meetingStart, waitTimeout: .seconds(2))

        let timedOutState = await coordinator.diarizerPreloadStateForTesting()
        #expect(timedOutState.isActive)
        #expect(timedOutState.waiterCount == 0)

        await loader.release()
        #expect(await waitUntil {
            !(await coordinator.diarizerPreloadStateForTesting().isActive)
        })
        let failedEvent = diagnostics.recorder.events().last { $0.0 == "diarizer.preload.failed" }
        #expect(failedEvent?.1["failure_category"] == "timeout")
        diagnostics.cleanup()
    }

    @Test("cancelled joined required preload never enters backend loading")
    func cancelledRequiredPreloadStopsBeforeBackend() async throws {
        let loader = BlockingLoader()
        let diagnostics = try makeDiagnostics(suffix: "cancelled-required-preload")
        let coordinator = TranscriptionCoordinator(
            diarizerModelLoader: { _ in
                await loader.waitUntilReleased()
                throw TestLoadError.failed
            },
            vadLoader: { throw TestLoadError.failed },
            diarizerDiagnostics: diagnostics.value
        )
        let invalidBackend = BackendOption(
            backend: "must-not-load",
            model: "none",
            label: "Test",
            sizeLabel: "0 MB",
            description: "Cancellation boundary test",
            recommended: false
        )

        let initiatingCaller = Task {
            await coordinator.preloadDiarizer(trigger: .appLaunch, waitTimeout: .seconds(5))
        }
        #expect(await waitUntil {
            let state = await coordinator.diarizerPreloadStateForTesting()
            return await loader.attempts == 1 && state.waiterCount == 1
        })

        let joinedCaller = Task { () -> String in
            do {
                try await coordinator.preloadRequired(
                    backend: invalidBackend,
                    includeMeetingHelpers: true,
                    meetingHelperTrigger: .meetingStart
                )
                return "completed"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "unexpected_error"
            }
        }
        #expect(await waitUntil {
            await coordinator.diarizerPreloadStateForTesting().waiterCount == 2
        })

        joinedCaller.cancel()
        #expect(await joinedCaller.value == "cancelled")
        #expect(await coordinator.diarizerPreloadStateForTesting().waiterCount == 1)

        await loader.release()
        await initiatingCaller.value
        diagnostics.cleanup()
    }

    private func makeDiagnostics(
        suffix: String
    ) throws -> (
        value: DiarizerPreloadDiagnostics,
        recorder: LockedSignalRecorder,
        cleanup: () -> Void
    ) {
        let suiteName = "DiarizerPreloadCoordinationTests.\(suffix).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let recorder = LockedSignalRecorder()
        return (
            DiarizerPreloadDiagnostics(defaults: defaults, signalSink: recorder.record),
            recorder,
            { defaults.removePersistentDomain(forName: suiteName) }
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}
