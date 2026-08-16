import AVFoundation
import CoreMedia
import Foundation
import MuesliCore
import Speech

struct AppleSpeechTranscriptAccumulator: Sendable {
    private(set) var text = ""
    private(set) var segments: [SpeechSegment] = []

    mutating func receive(text rawText: String, isFinal: Bool, start: Double, end: Double) {
        guard isFinal else { return }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if !text.isEmpty {
            text.append(" ")
        }
        text.append(trimmed)

        let safeStart = start.isFinite ? max(0, start) : 0
        let safeEnd = end.isFinite ? max(safeStart, end) : safeStart
        segments.append(SpeechSegment(start: safeStart, end: safeEnd, text: trimmed))
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
actor AppleSpeechAnalyzerTranscriber {
    static let modelID = "apple-speech-transcriber"

    static var isSupportedOnCurrentSystem: Bool {
        SpeechTranscriber.isAvailable
    }

    private var preparedLocale: Locale?

    func prepare(
        requestedLocale: Locale = .current,
        progress: ((Double, String?) -> Void)? = nil,
        progressSnapshot: ModelDownloadProgressHandler? = nil
    ) async throws -> Locale {
        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechAnalyzerError.unavailable
        }

        let locale = try await resolveLocale(requestedLocale)
        let transcriber = makeTranscriber(locale: locale)
        let status = await AssetInventory.status(forModules: [transcriber])

        if preparedLocale == locale, status == .installed {
            progress?(1, "Apple Speech ready")
            progressSnapshot?(readySnapshot())
            return locale
        }

        progress?(0.05, "Preparing Apple Speech for \(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)...")
        progressSnapshot?(ModelDownloadProgress.preparing(
            modelID: Self.modelID,
            message: "Preparing Apple Speech..."
        ))

        try await reserve(locale: locale)
        try Task.checkCancellation()

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let progressBox = AppleSpeechProgressBox(request.progress)
            let progressTask = Task { [progress, progressSnapshot] in
                while !Task.isCancelled && !progressBox.progress.isFinished {
                    let fraction = min(max(progressBox.progress.fractionCompleted, 0), 1)
                    let mappedFraction = 0.1 + (fraction * 0.8)
                    progress?(mappedFraction, "Downloading Apple Speech...")
                    progressSnapshot?(downloadSnapshot(fraction: fraction))
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

        preparedLocale = locale
        progress?(1, "Apple Speech ready")
        progressSnapshot?(readySnapshot())
        fputs("[muesli-native] Apple Speech ready for \(locale.identifier(.bcp47))\n", stderr)
        return locale
    }

    func transcribe(wavURL: URL, requestedLocale: Locale = .current) async throws -> SpeechTranscriptionResult {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let locale = try await prepare(requestedLocale: requestedLocale)
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
            "[muesli-native] Apple Speech result: \(result.text.prefix(80)) (locale \(locale.identifier(.bcp47)), took \(elapsedText)s)\n",
            stderr
        )
        return result
    }

    private func resolveLocale(_ requestedLocale: Locale) async throws -> Locale {
        if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) {
            return locale
        }

        let languageCode = requestedLocale.language.languageCode?.identifier
        if let languageCode,
           let languageLocale = await SpeechTranscriber.supportedLocale(
               equivalentTo: Locale(identifier: languageCode)
           ) {
            return languageLocale
        }

        if let english = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: "en-US")
        ) {
            fputs(
                "[muesli-native] Apple Speech locale \(requestedLocale.identifier(.bcp47)) unavailable; using \(english.identifier(.bcp47))\n",
                stderr
            )
            return english
        }

        guard let firstSupported = await SpeechTranscriber.supportedLocales.first else {
            throw AppleSpeechAnalyzerError.unsupportedLocale(requestedLocale.identifier(.bcp47))
        }
        return firstSupported
    }

    private func reserve(locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        if reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            return
        }

        guard reserved.count < max(1, AssetInventory.maximumReservedLocales),
              try await AssetInventory.reserve(locale: locale) else {
            throw AppleSpeechAnalyzerError.reservationUnavailable(AssetInventory.maximumReservedLocales)
        }
    }

    private func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
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
