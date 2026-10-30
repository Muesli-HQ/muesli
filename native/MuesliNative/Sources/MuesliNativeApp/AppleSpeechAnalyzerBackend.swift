import AVFoundation
import CoreMedia
import Foundation
import MuesliCore
import Speech

struct AppleSpeechTranscriptAccumulator: Sendable {
    private struct Result: Sendable {
        let rawText: String
        let text: String
        let isFinal: Bool
        let start: Double
        let end: Double
    }

    private var results: [Result] = []

    var text: String {
        results
            .sorted(by: Self.sortResults)
            .map(\.rawText)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var segments: [SpeechSegment] {
        results
            .filter(\.isFinal)
            .sorted(by: Self.sortResults)
            .map { SpeechSegment(start: $0.start, end: $0.end, text: $0.text) }
    }

    mutating func receive(text rawText: String, isFinal: Bool, start: Double, end: Double) {
        let safeStart = start.isFinite ? max(0, start) : 0
        let safeEnd = end.isFinite ? max(safeStart, end) : safeStart
        results.removeAll { existing in
            guard !existing.isFinal else { return false }
            return Self.overlaps(
                start: existing.start,
                end: existing.end,
                otherStart: safeStart,
                otherEnd: safeEnd
            )
        }

        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        results.append(Result(
            rawText: rawText,
            text: trimmed,
            isFinal: isFinal,
            start: safeStart,
            end: safeEnd
        ))
    }

    private static func overlaps(
        start: Double,
        end: Double,
        otherStart: Double,
        otherEnd: Double
    ) -> Bool {
        if start == end || otherStart == otherEnd {
            return start == otherStart
        }
        return start < otherEnd && otherStart < end
    }

    private static func sortResults(_ lhs: Result, _ rhs: Result) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        return lhs.isFinal && !rhs.isFinal
    }
}

struct AppleSpeechLanguageOption: Identifiable, Hashable, Sendable {
    static let systemIdentifier = "system"

    let id: String
    let label: String

    static func normalize(_ identifier: String?) -> String {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? systemIdentifier : trimmed
    }

    static func requestedLocale(for identifier: String) -> Locale {
        let normalized = normalize(identifier)
        return normalized == systemIdentifier ? .current : Locale(identifier: normalized)
    }

    static var system: AppleSpeechLanguageOption {
        let locale = Locale.current
        let localeName = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        return AppleSpeechLanguageOption(
            id: systemIdentifier,
            label: "System Language - \(localeName)"
        )
    }

    static func locale(_ locale: Locale) -> AppleSpeechLanguageOption {
        let identifier = locale.identifier(.bcp47)
        return AppleSpeechLanguageOption(
            id: identifier,
            label: Locale.current.localizedString(forIdentifier: identifier) ?? identifier
        )
    }
}

enum AppleSpeechInitialReservationPolicy {
    static func localesToRelease(_ reservations: [Locale], keeping locale: Locale,
                                activeIdentifiers: Set<String> = []) -> [Locale] {
        let protected = activeIdentifiers.union([locale.identifier(.bcp47)])
        return reservations.filter { !protected.contains($0.identifier(.bcp47)) }
    }
}

struct AppleSpeechReservationLeases {
    private var locales: [UUID: Locale] = [:]
    var identifiers: Set<String> { Set(locales.values.map { $0.identifier(.bcp47) }) }
    mutating func retain(_ locale: Locale) -> UUID {
        let id = UUID()
        locales[id] = locale
        return id
    }
    mutating func release(_ id: UUID) { locales.removeValue(forKey: id) }
}

/// Asset installation can return after an unsuccessful initial attempt. Retry
/// only readiness/download failures, never unsupported hardware or languages.
enum AppleSpeechPreparationRetry {
    static func isTransient(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let error = error as? AppleSpeechAnalyzerError {
            if case .assetUnavailable = error { return true }
            return false
        }
        let error = error as NSError
        if error.domain == NSURLErrorDomain {
            return [NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                    NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed,
                    NSURLErrorNotConnectedToInternet].contains(error.code)
        }
        return error.domain == "SFSpeechErrorDomain" && error.code == 1
    }

    static func run(
        delays: [Duration] = [.milliseconds(500), .seconds(1)],
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        operation: () async throws -> Void
    ) async throws {
        for attempt in 0...delays.count {
            try Task.checkCancellation()
            do {
                try await operation()
                try Task.checkCancellation()
                return
            } catch {
                guard attempt < delays.count, isTransient(error), !Task.isCancelled else { throw error }
                try await sleep(delays[attempt])
            }
        }
    }
}

struct AppleSpeechLocaleResolver: Sendable {
    let supportedLocale: @Sendable (Locale) async -> Locale?

    func resolve(_ requestedLocale: Locale) async throws -> Locale {
        if let locale = await supportedLocale(requestedLocale) {
            return locale
        }

        if let languageCode = requestedLocale.language.languageCode?.identifier,
           let languageLocale = await supportedLocale(Locale(identifier: languageCode)) {
            return languageLocale
        }

        throw AppleSpeechAnalyzerError.unsupportedLocale(requestedLocale.identifier(.bcp47))
    }
}

actor AppleSpeechPreparationTaskCache {
    private var tasks: [String: Task<Locale, Error>] = [:]
    private var tail: Task<Void, Never>?
    private let serializesOperations: Bool

    init(serializesOperations: Bool = false) {
        self.serializesOperations = serializesOperations
    }

    func value(
        for localeIdentifier: String,
        operation: @escaping @Sendable () async throws -> Locale
    ) async throws -> Locale {
        if let task = tasks[localeIdentifier] {
            return try await task.value
        }

        // Only inventory mutations need a serial lane, not downloads or probes.
        let predecessor = tail
        let task = Task {
            await predecessor?.value
            return try await operation()
        }
        if serializesOperations { tail = Task { _ = try? await task.value } }
        tasks[localeIdentifier] = task
        do {
            let locale = try await task.value
            tasks.removeValue(forKey: localeIdentifier)
            return locale
        } catch {
            tasks.removeValue(forKey: localeIdentifier)
            throw error
        }
    }
}

enum AppleSpeechAnalyzerError: LocalizedError, Sendable {
    case unavailable
    case unsupportedLocale(String)
    case assetUnavailable(String)
    case reservationUnavailable(Int)
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Apple Speech requires macOS 26 and compatible Apple hardware."
        case .unsupportedLocale(let identifier):
            return "Apple Speech does not support the \(identifier) locale on this Mac."
        case .assetUnavailable(let identifier):
            return "The Apple Speech model for \(identifier) is unavailable."
        case .reservationUnavailable(let maximum):
            return "Apple Speech cannot reserve another language on this Mac (limit: \(maximum))."
        case .emptyTranscript:
            return "Apple Speech completed without producing a transcript."
        }
    }
}

@available(macOS 26.0, *)
extension AppleSpeechLocaleResolver {
    static let live = AppleSpeechLocaleResolver { locale in
        await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }
}

@available(macOS 26.0, *)
extension AppleSpeechLanguageOption {
    static func supportedOptions() async -> [AppleSpeechLanguageOption] {
        let localeOptions = await SpeechTranscriber.supportedLocales
            .map(AppleSpeechLanguageOption.locale)
            .reduce(into: [String: AppleSpeechLanguageOption]()) { options, option in
                options[option.id] = option
            }
            .values
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        return [.system] + localeOptions
    }
}

@available(macOS 26.0, *)
actor AppleSpeechAnalyzerTranscriber {
    static let modelID = "apple-speech-transcriber"
    static let shared = AppleSpeechAnalyzerTranscriber()

    static var isSupportedOnCurrentSystem: Bool {
        // Keep system-model discovery consistent with the shared OS guard and UI preview.
        if !BackendOption.appleSpeechAnalyzer.isCompatible() {
            return false
        }
        return SpeechTranscriber.isAvailable
    }

    private let localeResolver: AppleSpeechLocaleResolver
    private let preparationTasks = AppleSpeechPreparationTaskCache()
    private let reservationTasks = AppleSpeechPreparationTaskCache(serializesOperations: true)
    private var preparedLocale: Locale?
    private var selectedLocale: Locale?
    private var activeUses = AppleSpeechReservationLeases()

    init(localeResolver: AppleSpeechLocaleResolver = .live) {
        self.localeResolver = localeResolver
    }

    func prepare(
        requestedLocale: Locale = .current,
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws -> Locale {
        let use = try await prepareAndRetain(requestedLocale: requestedLocale,
            progress: progress, progressSnapshot: progressSnapshot)
        releaseUse(use.id)
        return use.locale
    }

    func prepareSelectedLanguage(_ requestedLocale: Locale) async throws {
        let locale = try await localeResolver.resolve(requestedLocale)
        selectedLocale = locale
        _ = try await prepare(requestedLocale: locale)
    }

    /// A lease protects a locale across dictation, both live meeting sources,
    /// and concurrent preparation. Releasing it does not evict downloaded assets.
    func prepareAndRetain(
        requestedLocale: Locale,
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws -> (locale: Locale, id: UUID) {
        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechAnalyzerError.unavailable
        }

        let locale = try await localeResolver.resolve(requestedLocale)
        let id = activeUses.retain(locale)
        let callbacks = AppleSpeechPreparationCallbacks(
            progress: progress,
            progressSnapshot: progressSnapshot
        )
        do {
            let prepared = try await preparationTasks.value(
                for: locale.identifier(.bcp47)
            ) { [self, callbacks] in
                try await performPrepare(locale: locale, callbacks: callbacks)
            }
            try Task.checkCancellation()
            callbacks.progress?(1, "Apple Speech ready")
            callbacks.progressSnapshot?(readySnapshot())
            return (prepared, id)
        } catch {
            releaseUse(id)
            throw error
        }
    }

    func releaseUse(_ id: UUID) { activeUses.release(id) }

    private func performPrepare(
        locale: Locale,
        callbacks: AppleSpeechPreparationCallbacks
    ) async throws -> Locale {
        try await AppleSpeechPreparationRetry.run {
            try await self.prepareAttempt(locale: locale, callbacks: callbacks)
        }
        return locale
    }

    private func prepareAttempt(locale: Locale, callbacks: AppleSpeechPreparationCallbacks) async throws {
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        let status = await AssetInventory.status(forModules: [transcriber])

        let wasVerified = preparedLocale == locale && status == .installed

        callbacks.progress?(0.05, "Preparing Apple Speech for \(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)...")
        callbacks.progressSnapshot?(ModelDownloadProgress.preparing(
            modelID: Self.modelID,
            message: "Preparing Apple Speech..."
        ))

        _ = try await reservationTasks.value(for: locale.identifier(.bcp47)) { [self] in
            try await reserve(locale)
            return locale
        }
        try Task.checkCancellation()
        // Reassert our subscription even if another app keeps the assets installed.
        if wasVerified { return }

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let progressBox = AppleSpeechProgressBox(request.progress)
            let progressTask = Task { [callbacks] in
                while !Task.isCancelled && !progressBox.progress.isFinished {
                    let fraction = min(max(progressBox.progress.fractionCompleted, 0), 1)
                    let mappedFraction = 0.1 + (fraction * 0.8)
                    callbacks.progress?(mappedFraction, "Downloading Apple Speech...")
                    callbacks.progressSnapshot?(downloadSnapshot(fraction: fraction))
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            defer { progressTask.cancel() }

            try await withTaskCancellationHandler {
                try await request.downloadAndInstall()
            } onCancel: {
                progressBox.progress.cancel()
            }
        }

        try Task.checkCancellation()
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw AppleSpeechAnalyzerError.assetUnavailable(locale.identifier(.bcp47))
        }

        // Verify the actual live configuration, not merely framework support
        // or completion of the download request. Release the probe afterwards.
        let analyzer = SpeechAnalyzer(modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering))
        do {
            let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                sampleRate: 16_000, channels: 1, interleaved: true)!
            try await analyzer.prepareToAnalyze(in: format)
            try Task.checkCancellation()
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
        await analyzer.cancelAndFinishNow()
        preparedLocale = locale
        fputs("[muesli-native] Apple Speech ready for \(locale.identifier(.bcp47))\n", stderr)
    }

    private func reserve(_ locale: Locale) async throws {
        let reservations = await AssetInventory.reservedLocales
        // Normal preparation/unloading never evicts assets. Reclaim stale
        // reservations only when a new language needs a slot, preserving the
        // explicit selection and every currently leased language.
        if reservations.count >= AssetInventory.maximumReservedLocales,
           !reservations.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            let protected = activeUses.identifiers.union([selectedLocale?.identifier(.bcp47)].compactMap { $0 })
            for stale in AppleSpeechInitialReservationPolicy.localesToRelease(
                reservations, keeping: locale,
                activeIdentifiers: protected
            ) {
                _ = await AssetInventory.release(reservedLocale: stale)
            }
        }
        do {
            _ = try await AssetInventory.reserve(locale: locale)
        } catch {
            let reservedCount = (await AssetInventory.reservedLocales).count
            if reservedCount >= AssetInventory.maximumReservedLocales {
                throw AppleSpeechAnalyzerError.reservationUnavailable(AssetInventory.maximumReservedLocales)
            }
            throw error
        }
    }

    func transcribe(wavURL: URL, requestedLocale: Locale = .current) async throws -> SpeechTranscriptionResult {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let use = try await prepareAndRetain(requestedLocale: requestedLocale)
        defer { releaseUse(use.id) }
        let locale = use.locale
        let transcriber = makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )
        let audioFile = try AVAudioFile(forReading: wavURL)

        async let collected = collectResults(from: transcriber)
        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let result = try await collected
        guard !result.text.isEmpty else {
            throw AppleSpeechAnalyzerError.emptyTranscript
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
        let elapsedText = String(format: "%.3f", elapsed)
        fputs(
            "[muesli-native] Apple Speech completed \(result.text.count) characters in \(elapsedText)s (locale \(locale.identifier(.bcp47)))\n",
            stderr
        )
        return result
    }

    private func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
    }

    private func collectResults(from transcriber: SpeechTranscriber) async throws -> SpeechTranscriptionResult {
        var accumulator = AppleSpeechTranscriptAccumulator()
        for try await result in transcriber.results {
            let start = CMTimeGetSeconds(result.range.start)
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
            accumulator.receive(
                text: String(result.text.characters),
                isFinal: result.isFinal,
                start: start,
                end: end
            )
        }
        return SpeechTranscriptionResult(text: accumulator.text, segments: accumulator.segments)
    }

    private func downloadSnapshot(fraction: Double) -> ModelDownloadProgress {
        let total: Int64 = 10_000
        return ModelDownloadProgress(
            modelID: Self.modelID,
            phase: .downloading,
            currentFile: nil,
            completedBytes: Int64(Double(total) * fraction),
            totalBytes: total,
            currentFileCompletedBytes: 0,
            currentFileTotalBytes: nil,
            bytesPerSecond: 0,
            estimatedSecondsRemaining: nil,
            retryCount: 0,
            message: "Downloading Apple Speech..."
        )
    }

    private func readySnapshot() -> ModelDownloadProgress {
        ModelDownloadProgress.preparing(
            modelID: Self.modelID,
            message: "Apple Speech ready"
        ).replacing(phase: .ready, message: "Apple Speech ready")
    }
}

@available(macOS 26.0, *)
private final class AppleSpeechProgressBox: @unchecked Sendable {
    let progress: Progress

    init(_ progress: Progress) {
        self.progress = progress
    }
}

private final class AppleSpeechPreparationCallbacks: @unchecked Sendable {
    let progress: ((Double, String?) -> Void)?
    let progressSnapshot: ModelDownloadProgressHandler?

    init(
        progress: ((Double, String?) -> Void)?,
        progressSnapshot: ModelDownloadProgressHandler?
    ) {
        self.progress = progress
        self.progressSnapshot = progressSnapshot
    }
}
