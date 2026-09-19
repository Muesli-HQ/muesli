import AppKit
import AVFoundation
import FluidAudio
import Foundation
import MuesliCore
import UniformTypeIdentifiers

/// Handles importing audio files (m4a, mp4, wav, mp3) for offline transcription.
/// Converts the source file to 16kHz mono WAV, transcribes it, optionally runs
/// speaker diarization, and creates a meeting record with the result.
enum AudioFileImportController {
    static let supportedExtensions: Set<String> = ["m4a", "mp4", "wav", "mp3"]

    private static let allowedTypes: [UTType] = {
        var types: [UTType] = [
            .wav,
            .mp3,
            .mpeg4Audio,
            .appleProtectedMPEG4Audio,
        ]
        if let m4a = UTType(filenameExtension: "m4a") { types.append(m4a) }
        if let mp4 = UTType(filenameExtension: "mp4") { types.append(mp4) }
        return types
    }()

    static func isSupportedFileURL(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - File Selection

    /// Presents an NSOpenPanel for selecting an audio file and returns the chosen URL.
    static func selectFile() async -> URL? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let panel = NSOpenPanel()
                panel.title = "Import Audio File for Transcription"
                panel.message = "Choose an audio file (m4a, mp4, wav, mp3)"
                panel.allowedContentTypes = allowedTypes
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                panel.canCreateDirectories = false

                NSApp.activate()
                if let window = NSApp.keyWindow {
                    panel.beginSheetModal(for: window) { response in
                        continuation.resume(
                            returning: response == .OK ? panel.url : nil
                        )
                    }
                } else {
                    panel.begin { response in
                        continuation.resume(
                            returning: response == .OK ? panel.url : nil
                        )
                    }
                }
            }
        }
    }

    // MARK: - Audio Conversion

    enum ImportError: Error, Equatable, LocalizedError {
        case unsupportedFormat
        case conversionFailed(String)
        case noAudioTracks
        case readError(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                return "This audio file format is not supported."
            case .conversionFailed(let detail):
                return "Could not convert the audio file. \(detail)"
            case .noAudioTracks:
                return "The selected file does not contain any audio tracks."
            case .readError(let detail):
                return "Could not read the audio file. \(detail)"
            }
        }
    }

    /// Converts the source audio file to 16kHz mono WAV for transcription.
    /// Returns the temporary WAV URL and the audio duration in seconds.
    static func convertToWAV(sourceURL: URL) async throws -> (wavURL: URL, duration: TimeInterval) {
        guard isSupportedFileURL(sourceURL) else {
            throw ImportError.unsupportedFormat
        }
        try Task.checkCancellation()

        if let compatibleWAV = try compatibleWAVInfo(sourceURL: sourceURL) {
            let outputURL = try temporaryWAVURL()
            do {
                try FileManager.default.copyItem(at: sourceURL, to: outputURL)
                try Task.checkCancellation()
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                throw error
            }
            return (outputURL, compatibleWAV.duration)
        }

        let duration = try await audioDuration(sourceURL: sourceURL)
        try Task.checkCancellation()

        let (wavURL, decodedDuration) = try await decodeWAVWithAssetReader(sourceURL: sourceURL)
        let resolvedDuration = duration ?? decodedDuration
        guard resolvedDuration > 0, resolvedDuration.isFinite else {
            try? FileManager.default.removeItem(at: wavURL)
            throw ImportError.readError("Invalid audio duration.")
        }
        return (wavURL, resolvedDuration)
    }

    // MARK: - Import Pipeline

    struct ImportResult {
        let meetingID: Int64
        let title: String
        let rawTranscript: String
        let formattedNotes: String
        let durationSeconds: Double
        let wordCount: Int
    }

    struct ImportContext {
        let config: AppConfig
        let backend: BackendOption
        let transcriptionCoordinator: TranscriptionCoordinator
        let templateSnapshot: MeetingTemplateSnapshot
    }

    /// Runs the full import pipeline: convert, transcribe, diarize, format, persist, summarize.
    static func importAudioFile(
        sourceURL: URL,
        title: String,
        controller: MuesliController,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> ImportResult {
        progress("Converting audio file...")
        let (wavURL, duration) = try await convertToWAV(sourceURL: sourceURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        try Task.checkCancellation()

        let context = await controller.audioFileImportContext()
        let config = context.config
        let backend = context.backend
        let transcriptionCoordinator = context.transcriptionCoordinator

        progress("Loading transcription model...")
        try await transcriptionCoordinator.preloadRequired(
            backend: backend,
            enablePostProcessor: false,
            includeMeetingHelpers: true,
            meetingHelperTrigger: .audioImport,
            appleSpeechLanguage: config.resolvedAppleSpeechLanguage
        )

        try Task.checkCancellation()

        // VAD runs per replay window, not against the whole imported file.
        await transcriptionCoordinator.setNemotron35PromptId(config.resolvedNemotron35Language.promptId)

        progress("Transcribing audio...")
        let transcription = try await transcriptionCoordinator.transcribeRecordedAudio(
            at: wavURL,
            backend: backend,
            cohereLanguage: config.resolvedCohereLanguage,
            bodhanLanguage: config.resolvedBodhanLanguage,
            whisperLanguage: config.resolvedWhisperLanguage,
            parakeetLanguage: config.resolvedParakeetLanguage,
            appleSpeechLanguage: config.resolvedAppleSpeechLanguage,
            progress: { fraction, _ in
                progress("Transcribing audio · \(Int(fraction * 100))%")
            }
        )
        let rawTranscript = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTranscript.isEmpty else {
            throw ImportError.readError("No speech was transcribed from the selected audio file.")
        }

        try Task.checkCancellation()

        // Run speaker diarization if available
        var diarizedTranscript = rawTranscript
        if let diarizerManager = await transcriptionCoordinator.getDiarizerManager(),
           diarizerManager.isAvailable {
            progress("Identifying speakers...")
            do {
                let converter = AudioConverter()
                let samples = try converter.resampleAudioFile(wavURL)
                try Task.checkCancellation()
                let diarizationResult = try diarizerManager.performCompleteDiarization(
                    samples,
                    sampleRate: 16000
                )
                if !diarizationResult.segments.isEmpty {
                    diarizedTranscript = formatTranscriptWithSpeakers(
                        transcription: transcription,
                        diarizationSegments: diarizationResult.segments,
                        meetingStart: importedTranscriptTimelineStart()
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                fputs("[import] diarization failed, using raw transcript: \(error)\n", stderr)
            }
        }

        try Task.checkCancellation()

        let wordCount = DictationStore.countWords(in: diarizedTranscript)
        let generatedTitle: String
        progress("Generating title...")
        if let autoTitle = await MeetingSummaryClient.generateTitle(transcript: diarizedTranscript, config: config),
           !autoTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            generatedTitle = autoTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            generatedTitle = title
        }

        try Task.checkCancellation()

        progress("Generating summary...")
        let templateSnapshot = context.templateSnapshot
        let formattedNotes: String
        do {
            formattedNotes = try await MeetingSummaryClient.summarize(
                transcript: diarizedTranscript,
                meetingTitle: generatedTitle,
                config: config,
                template: templateSnapshot,
                existingNotes: nil,
                manualNotesToRetain: ""
            )
        } catch {
            fputs("[import] summary generation failed: \(error)\n", stderr)
            formattedNotes = MeetingSummaryClient.summaryFailureNotes(
                transcript: diarizedTranscript,
                meetingTitle: generatedTitle,
                error: error,
                manualNotes: ""
            )
        }

        try Task.checkCancellation()

        // Persist the converted WAV as a saved recording so retranscription works
        let savedRecordingPath = try persistRecording(wavURL: wavURL, title: generatedTitle)

        progress("Saving...")
        let now = Date()
        let startTime = now.addingTimeInterval(-duration)
        let meetingID = try await controller.persistImportedAudioMeeting(
            title: generatedTitle,
            calendarEventID: nil,
            startTime: startTime,
            endTime: now,
            rawTranscript: diarizedTranscript,
            formattedNotes: formattedNotes,
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: savedRecordingPath,
            selectedTemplateID: templateSnapshot.id,
            selectedTemplateName: templateSnapshot.name,
            selectedTemplateKind: templateSnapshot.kind,
            selectedTemplatePrompt: templateSnapshot.prompt
        )

        return ImportResult(
            meetingID: meetingID,
            title: generatedTitle,
            rawTranscript: diarizedTranscript,
            formattedNotes: formattedNotes,
            durationSeconds: duration,
            wordCount: wordCount
        )
    }

    // MARK: - Helpers

    private static func temporaryWAVURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-import", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("import_\(UUID().uuidString).wav")
    }

    private struct CompatibleWAVInfo {
        let duration: TimeInterval
    }

    private static func compatibleWAVInfo(sourceURL: URL) throws -> CompatibleWAVInfo? {
        guard sourceURL.pathExtension.lowercased() == "wav" else { return nil }
        let file = try AVAudioFile(forReading: sourceURL)
        let fileFormat = file.fileFormat
        guard fileFormat.sampleRate == Double(WavWriter.sampleRate),
              fileFormat.channelCount == UInt32(WavWriter.channels),
              fileFormat.commonFormat == .pcmFormatInt16 else {
            return nil
        }
        let duration = Double(file.length) / fileFormat.sampleRate
        guard duration > 0, duration.isFinite else {
            throw ImportError.readError("Invalid audio duration.")
        }
        return CompatibleWAVInfo(duration: duration)
    }

    private static func audioDuration(sourceURL: URL) async throws -> TimeInterval? {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.load(.tracks)
        guard tracks.contains(where: { $0.mediaType == .audio }) else {
            throw ImportError.noAudioTracks
        }
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        return duration > 0 && duration.isFinite ? duration : nil
    }

    private static func decodeWAVWithAssetReader(sourceURL: URL) async throws -> (URL, TimeInterval) {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.load(.tracks)
        guard let audioTrack = tracks.first(where: { $0.mediaType == .audio }) else {
            throw ImportError.noAudioTracks
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ImportError.conversionFailed("Could not read audio samples from the selected file.")
        }
        reader.add(output)

        guard reader.startReading() else {
            throw ImportError.readError(reader.error?.localizedDescription ?? "Unknown read error")
        }
        defer { reader.cancelReading() }

        let wavURL = try temporaryWAVURL()
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: wavURL) } }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let writer = try AVAudioFile(forWriting: wavURL, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ])

        let converter = AudioConverter()
        var frameCount = 0
        while reader.status == .reading {
            try Task.checkCancellation()
            let didRead = try autoreleasepool {
                guard let sampleBuffer = output.copyNextSampleBuffer() else { return false }
                let samples = try converter.resampleSampleBuffer(sampleBuffer)
                guard !samples.isEmpty else { return true }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
                    throw ImportError.conversionFailed("Could not allocate conversion buffer.")
                }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer { source in
                    buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
                }
                try writer.write(from: buffer)
                frameCount += samples.count
                return true
            }
            if !didRead { break }
        }

        guard reader.status == .completed else {
            throw ImportError.readError(reader.error?.localizedDescription ?? "Read did not complete")
        }
        try Task.checkCancellation()
        guard frameCount > 0 else { throw ImportError.noAudioTracks }
        completed = true
        return (wavURL, Double(frameCount) / 16_000)
    }

    /// Copies the converted WAV to the meeting-recordings directory so the imported
    /// meeting can be retranscribed later.
    private static func persistRecording(wavURL: URL, title: String) throws -> String {
        let recordingsDirectory = AppIdentity.supportDirectoryURL
            .appendingPathComponent("meeting-recordings", isDirectory: true)
        try FileManager.default.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true
        )

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let datePrefix = dateFormatter.string(from: Date())
        let safeTitle = safeFilenameComponent(title)
        let filename = "\(datePrefix)_\(safeTitle)_\(UUID().uuidString.prefix(8)).wav"
        let destinationURL = recordingsDirectory.appendingPathComponent(filename)

        try FileManager.default.copyItem(at: wavURL, to: destinationURL)
        return destinationURL.path
    }

    private static func safeFilenameComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" })
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
        return collapsed.isEmpty ? "Imported-Recording" : String(collapsed.prefix(80))
    }

    private static func importedTranscriptTimelineStart() -> Date {
        Calendar.current.startOfDay(for: Date())
    }

    /// Formats transcript text with speaker labels based on diarization segments.
    /// When diarization identifies multiple speakers, the transcript is annotated with
    /// speaker labels using ASR segment timestamps so both the user and summarizer can
    /// attribute spoken text to individual speakers without inventing text boundaries.
    static func formatTranscriptWithSpeakers(
        transcription: SpeechTranscriptionResult,
        diarizationSegments: [TimedSpeakerSegment],
        meetingStart: Date
    ) -> String {
        let rawText = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty, !diarizationSegments.isEmpty else { return rawText }

        let speakerCount = Set(diarizationSegments.map(\.speakerId)).count
        guard speakerCount > 1 else { return rawText }

        if rawText.range(of: #"(?m)^\[[0-9]{2}:[0-9]{2}(?::[0-9]{2})?\]\s+(You|Others|Speaker\s+\d+):"#, options: .regularExpression) != nil {
            return rawText
        }

        let transcribedSegments = transcription.segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !transcribedSegments.isEmpty else { return rawText }

        let formatted = TranscriptFormatter.merge(
            micSegments: [],
            systemSegments: transcribedSegments,
            diarizationSegments: diarizationSegments,
            meetingStart: meetingStart
        )
        return formatted.isEmpty ? rawText : formatted
    }

    /// Backward-compatible helper for tests and any callers that only have raw text.
    static func formatTranscriptWithSpeakers(
        rawText: String,
        diarizationSegments: [TimedSpeakerSegment],
        duration: TimeInterval
    ) -> String {
        let transcription = SpeechTranscriptionResult(
            text: rawText,
            segments: [SpeechSegment(start: 0, end: max(duration, 0.1), text: rawText)]
        )
        return formatTranscriptWithSpeakers(
            transcription: transcription,
            diarizationSegments: diarizationSegments,
            meetingStart: importedTranscriptTimelineStart()
        )
    }
}
