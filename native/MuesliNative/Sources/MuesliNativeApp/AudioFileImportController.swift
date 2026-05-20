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

    enum ImportError: Error, LocalizedError {
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
        let asset = AVAsset(url: sourceURL)
        guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
            throw ImportError.noAudioTracks
        }

        let duration = CMTimeGetSeconds(asset.duration)
        guard duration > 0, duration.isFinite else {
            throw ImportError.readError("Invalid audio duration.")
        }

        let outputURL = try temporaryWAVURL()
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        let writer = try AVAssetWriter(url: outputURL, fileType: .wav)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        writerInput.expectsMediaDataInRealTime = false
        writer.add(writerInput)

        guard reader.startReading() else {
            throw ImportError.readError(reader.error?.localizedDescription ?? "Unknown read error")
        }
        guard writer.startWriting() else {
            throw ImportError.conversionFailed(writer.error?.localizedDescription ?? "Unknown write error")
        }
        writer.startSession(atSourceTime: .zero)

        // Use async dispatch group to avoid blocking cooperative thread pool
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "com.muesli.import.convert")
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(sampleBuffer)
                    } else {
                        writerInput.markAsFinished()
                        writer.finishWriting {
                            continuation.resume()
                        }
                        return
                    }
                }
            }
        }

        if let error = writer.error {
            try? FileManager.default.removeItem(at: outputURL)
            throw ImportError.conversionFailed(error.localizedDescription)
        }
        guard reader.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            throw ImportError.readError(reader.error?.localizedDescription ?? "Read did not complete")
        }

        return (outputURL, duration)
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

    /// Runs the full import pipeline: convert, transcribe, diarize, format, persist, summarize.
    static func importAudioFile(
        sourceURL: URL,
        title: String,
        controller: MuesliController,
        progress: @escaping (String) -> Void
    ) async throws -> ImportResult {
        progress("Converting audio file...")
        let (wavURL, duration) = try await convertToWAV(sourceURL: sourceURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        try Task.checkCancellation()

        let config = controller.config
        let backend = controller.selectedMeetingTranscriptionBackend
        let transcriptionCoordinator = controller.transcriptionCoordinator

        progress("Loading transcription model...")
        try await transcriptionCoordinator.preloadRequired(
            backend: backend,
            enablePostProcessor: false,
            includeMeetingHelpers: true
        )

        try Task.checkCancellation()

        // Run VAD to skip silent files (prevents Cohere hallucinations on silence)
        if let vadManager = transcriptionCoordinator.vadManager {
            do {
                let vadResults = try await vadManager.process(wavURL)
                let hasSpeech = vadResults.contains { $0.probability > 0.5 }
                if !hasSpeech {
                    throw ImportError.readError("No speech detected in the selected audio file.")
                }
            } catch let error as ImportError {
                throw error
            } catch {
                fputs("[import] VAD check failed, transcribing anyway: \(error)\n", stderr)
            }
        }

        try Task.checkCancellation()

        progress("Transcribing audio...")
        let transcription = try await transcriptionCoordinator.transcribeMeeting(
            at: wavURL,
            backend: backend,
            cohereLanguage: config.resolvedCohereLanguage
        )
        let rawTranscript = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTranscript.isEmpty else {
            throw ImportError.readError("No speech was transcribed from the selected audio file.")
        }

        try Task.checkCancellation()

        // Run speaker diarization if available
        var diarizedTranscript = rawTranscript
        if let diarizerManager = transcriptionCoordinator.getDiarizerManager(),
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
                        rawText: rawTranscript,
                        diarizationSegments: diarizationResult.segments,
                        duration: duration
                    )
                }
            } catch is CancellationError {
                throw ImportError.readError("Import was cancelled.")
            } catch {
                fputs("[import] diarization failed, using raw transcript: \(error)\n", stderr)
            }
        }

        try Task.checkCancellation()

        let wordCount = DictationStore.countWords(in: diarizedTranscript)

        progress("Generating summary...")
        let templateSnapshot = controller.defaultMeetingTemplate()
        let formattedNotes: String
        do {
            formattedNotes = try await MeetingSummaryClient.summarize(
                transcript: diarizedTranscript,
                meetingTitle: title,
                config: config,
                template: templateSnapshot,
                existingNotes: nil,
                manualNotesToRetain: ""
            )
        } catch {
            fputs("[import] summary generation failed: \(error)\n", stderr)
            formattedNotes = MeetingSummaryClient.summaryFailureNotes(
                transcript: diarizedTranscript,
                meetingTitle: title,
                error: error,
                manualNotes: ""
            )
        }

        try Task.checkCancellation()

        // Persist the converted WAV as a saved recording so retranscription works
        let savedRecordingPath = try persistRecording(wavURL: wavURL, title: title)

        progress("Saving...")
        let now = Date()
        let startTime = now.addingTimeInterval(-duration)
        let meetingID = try controller.dictationStore.insertMeeting(
            title: title,
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
            title: title,
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
        let safeTitle = title.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let filename = "\(datePrefix)_\(safeTitle).wav"
        let destinationURL = recordingsDirectory.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: wavURL, to: destinationURL)
        return destinationURL.path
    }

    /// Formats transcript text with speaker labels based on diarization segments.
    /// When diarization identifies multiple speakers, the transcript is annotated with
    /// speaker labels at segment boundaries so both the user and summarizer can
    /// attribute spoken text to individual speakers.
    static func formatTranscriptWithSpeakers(
        rawText: String,
        diarizationSegments: [TimedSpeakerSegment],
        duration: TimeInterval
    ) -> String {
        guard !diarizationSegments.isEmpty else { return rawText }

        let speakerCount = Set(diarizationSegments.map(\.speakerId)).count
        guard speakerCount > 1 else { return rawText }

        // If the raw text already has timestamped speaker lines, use those instead.
        if rawText.range(of: #"(?m)^\[[0-9]{2}:[0-9]{2}(?::[0-9]{2})?\]\s+(You|Others|Speaker\s+\d+):"#, options: .regularExpression) != nil {
            return rawText
        }

        // Build a speaker-labeled transcript using diarization segments
        var result = "## Speaker Segments\n"
        for segment in diarizationSegments {
            let startStr = formatTimeInterval(segment.startTime)
            let endStr = formatTimeInterval(segment.endTime)
            let speaker = segment.speakerId.replacingOccurrences(of: "SPEAKER_", with: "Speaker ")
            result += "[\(startStr) - \(endStr)] \(speaker)\n"
        }

        result += "\n## Transcript\n"

        // Annotate the transcript with speaker labels at segment boundaries
        let lines = rawText.components(separatedBy: .newlines)
        let segmentCount = diarizationSegments.count
        let lineCount = lines.count

        if lineCount > 0, segmentCount > 0 {
            let linesPerSegment = max(1, lineCount / segmentCount)
            for (i, line) in lines.enumerated() {
                let segmentIndex = min(i / linesPerSegment, segmentCount - 1)
                let speaker = diarizationSegments[segmentIndex].speakerId
                    .replacingOccurrences(of: "SPEAKER_", with: "Speaker ")
                let startStr = formatTimeInterval(diarizationSegments[segmentIndex].startTime)
                result += "[\(startStr)] \(speaker): \(line)\n"
            }
        } else {
            result += rawText
        }

        return result
    }

    private static func formatTimeInterval(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
