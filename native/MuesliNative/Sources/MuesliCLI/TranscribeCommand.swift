import ArgumentParser
import AVFoundation
import FluidAudio
import Foundation
import MuesliCore
import WhisperKit

enum TranscribeOutputFormat: String, CaseIterable, ExpressibleByArgument {
    case text
    case json
    case markdown
}

enum TranscribeModel: String, CaseIterable, ExpressibleByArgument, Encodable {
    case parakeetV3 = "parakeet-v3"
    case parakeetV2 = "parakeet-v2"
    case parakeetUnified = "parakeet-unified"
    case parakeetEou320ms = "parakeet-eou-320ms"
    case senseVoice = "sensevoice"
    case qwen3Asr = "qwen3-asr"
    case nemotron35 = "nemotron35"
    case whisperTiny = "whisper-tiny"
    case whisperTinyEnglish = "whisper-tiny-english"
    case whisperSmall = "whisper-small"
    case whisperSmallEnglish = "whisper-small-english"
    case whisperMediumEnglish = "whisper-medium-english"
    case whisperLargeTurbo = "whisper-large-turbo"

    /// `nil` for models that don't go through `FluidAudioCLITranscriber`'s
    /// batch `AsrManager` path (streaming, or a different FluidAudio manager).
    var asrModelVersion: AsrModelVersion? {
        switch self {
        case .parakeetV3: return .v3
        case .parakeetV2: return .v2
        case .parakeetUnified, .parakeetEou320ms, .senseVoice, .qwen3Asr, .nemotron35,
             .whisperTiny, .whisperTinyEnglish,
             .whisperSmall, .whisperSmallEnglish, .whisperMediumEnglish,
             .whisperLargeTurbo:
            return nil
        }
    }

    /// WhisperKit's model identifiers, shared with the app's Whisper backend.
    var whisperKitModelName: String? {
        switch self {
        case .whisperTiny: return "tiny"
        case .whisperTinyEnglish: return "tiny.en"
        case .whisperSmall: return "small"
        case .whisperSmallEnglish: return "small.en"
        case .whisperMediumEnglish: return "medium.en"
        case .whisperLargeTurbo: return "large-v3-v20240930_626MB"
        case .parakeetV3, .parakeetV2, .parakeetUnified, .parakeetEou320ms, .senseVoice, .qwen3Asr, .nemotron35:
            return nil
        }
    }

}

struct TranscribeJSONPayload: Encodable {
    let transcript: String
    let summary: String?
    let durationSeconds: Double
    let wordCount: Int
    let model: String
    let warnings: [String]
    let savedMeetingID: Int64?
    let title: String

    enum CodingKeys: String, CodingKey {
        case transcript
        case summary
        case durationSeconds
        case wordCount
        case model
        case warnings
        case savedMeetingID
        case title
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transcript, forKey: .transcript)
        if let summary {
            try container.encode(summary, forKey: .summary)
        } else {
            try container.encodeNil(forKey: .summary)
        }
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try container.encode(wordCount, forKey: .wordCount)
        try container.encode(model, forKey: .model)
        try container.encode(warnings, forKey: .warnings)
        if let savedMeetingID {
            try container.encode(savedMeetingID, forKey: .savedMeetingID)
        } else {
            try container.encodeNil(forKey: .savedMeetingID)
        }
        try container.encode(title, forKey: .title)
    }
}

struct TranscribeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe a local audio file with Muesli's bundled local ASR models."
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: "Audio file to transcribe. Supported extensions: mp3, mp4, m4a, wav.")
    var file: String
    @Option(name: .long, help: "Output format: text, json, or markdown.")
    var format: TranscribeOutputFormat = .text
    @Option(name: .long, help: "Transcription model: parakeet-v3, parakeet-v2, parakeet-unified, parakeet-eou-320ms (streaming), sensevoice, qwen3-asr, nemotron35, whisper-tiny, whisper-tiny-english, whisper-small, whisper-small-english, whisper-medium-english, or whisper-large-turbo.")
    var model: TranscribeModel = .parakeetUnified
    @Flag(name: .long, help: "Generate meeting notes using the configured Muesli summary backend when available.")
    var summarize = false
    @Flag(name: .long, help: "Save the transcript as an imported Muesli meeting.")
    var saveMeeting = false
    @Option(name: .long, help: "Optional title override for saved meetings and markdown output.")
    var title: String?
    @Option(name: .long, help: "Write command output to a file instead of stdout.")
    var output: String?
    @Option(name: .long, help: "Path to a portable dictionary JSON array ({word, replacement, matching_threshold}), or an app config JSON object with custom_words, to apply to the transcript.")
    var dictionary: String?

    mutating func validate() throws {
        let url = URL(fileURLWithPath: file)
        guard MuesliAudioFilePreparer.isSupportedFileURL(url) else {
            throw ValidationError("Unsupported audio file extension. Supported extensions: mp3, mp4, m4a, wav.")
        }
    }

    func run() async throws {
        let context = CLIContext(options: global)
        let sourceURL = URL(fileURLWithPath: file).standardizedFileURL
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw CLIError.notFound("Audio file does not exist: \(sourceURL.path)", fix: "Pass a local .mp3, .mp4, .m4a, or .wav file path.")
        }

        let pipeline = MuesliAudioTranscriptionPipeline()
        let result = try await pipeline.run(
            request: MuesliAudioTranscriptionRequest(
                sourceURL: sourceURL,
                model: model,
                title: title,
                summarize: summarize,
                saveMeeting: saveMeeting,
                dictionaryURL: dictionary.map { URL(fileURLWithPath: $0) }
            ),
            context: context
        )

        let outputText: String
        switch format {
        case .text:
            outputText = result.textOutput
        case .markdown:
            outputText = result.markdownOutput + "\n"
        case .json:
            let payload = TranscribeJSONPayload(result)
            let envelope = SuccessEnvelope(
                command: "muesli-cli transcribe",
                data: payload,
                meta: MetaBody(
                    schemaVersion: 1,
                    generatedAt: timestampString(),
                    dbPath: context.databaseURL.path,
                    warnings: result.warnings
                )
            )
            outputText = String(decoding: try encodedJSON(envelope), as: UTF8.self)
        }

        if let output {
            try writeOutput(outputText, to: URL(fileURLWithPath: output))
        } else {
            FileHandle.standardOutput.write(Data(outputText.utf8))
        }
    }
}

extension TranscribeJSONPayload {
    init(_ result: MuesliAudioTranscriptionResult) {
        self.init(
            transcript: result.transcript,
            summary: result.summary,
            durationSeconds: result.durationSeconds,
            wordCount: result.wordCount,
            model: result.model.rawValue,
            warnings: result.warnings,
            savedMeetingID: result.savedMeetingID,
            title: result.title
        )
    }
}

func encodedJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var data = try encoder.encode(value)
    data.append(Data("\n".utf8))
    return data
}

func writeOutput(_ text: String, to url: URL) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url, options: .atomic)
}

struct MuesliAudioTranscriptionRequest {
    let sourceURL: URL
    let model: TranscribeModel
    let title: String?
    let summarize: Bool
    let saveMeeting: Bool
    /// Path to a JSON array of `CustomWord`-shaped entries. When set, applied to the
    /// transcript via `CustomWordMatcher.apply` after transcription — the same dictionary
    /// correction step Muesli applies to dictations, so this measures "what if the
    /// dictionary were enabled" against exactly the shipped implementation.
    var dictionaryURL: URL? = nil
}

struct MuesliAudioTranscriptionResult {
    let title: String
    let transcript: String
    let summary: String?
    let durationSeconds: Double
    let wordCount: Int
    let model: TranscribeModel
    let warnings: [String]
    let savedMeetingID: Int64?

    var textOutput: String {
        transcript + "\n"
    }

    var markdownOutput: String {
        var sections = ["# \(title)"]
        if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(summary)
        }
        sections.append("## Raw Transcript\n\n\(transcript)")
        return sections.joined(separator: "\n\n")
    }
}

struct PreparedAudioFile {
    let wavURL: URL
    let durationSeconds: Double
    let deleteWhenDone: Bool
}

protocol AudioPreparing {
    func prepareAudio(sourceURL: URL) async throws -> PreparedAudioFile
}

protocol AudioTranscribing {
    func transcribe(wavURL: URL, model: TranscribeModel, progress: @escaping (String) -> Void) async throws -> HeadlessTranscription
}

protocol MeetingSummarizing {
    func summarize(transcript: String, title: String, supportDirectory: URL) async throws -> String
}

struct HeadlessTranscription {
    let text: String
    let durationSeconds: Double?
}

struct MuesliAudioTranscriptionPipeline {
    var audioPreparer: AudioPreparing
    var transcriber: AudioTranscribing
    var summarizer: MeetingSummarizing
    var dataChangePoster: () -> Void

    init(
        audioPreparer: AudioPreparing = MuesliAudioFilePreparer(),
        transcriber: AudioTranscribing = RoutingAudioTranscriber(),
        summarizer: MeetingSummarizing = ConfiguredCLIMeetingSummarizer(),
        dataChangePoster: @escaping () -> Void = MuesliNotifications.postDataDidChange
    ) {
        self.audioPreparer = audioPreparer
        self.transcriber = transcriber
        self.summarizer = summarizer
        self.dataChangePoster = dataChangePoster
    }

    func run(request: MuesliAudioTranscriptionRequest, context: CLIContext) async throws -> MuesliAudioTranscriptionResult {
        let customWords: [CustomWord]?
        if let dictionaryURL = request.dictionaryURL {
            customWords = try Self.loadCustomWords(from: dictionaryURL)
        } else {
            customWords = nil
        }

        fputs("[muesli-cli] preparing audio...\n", stderr)
        let prepared = try await audioPreparer.prepareAudio(sourceURL: request.sourceURL)
        defer {
            if prepared.deleteWhenDone {
                try? FileManager.default.removeItem(at: prepared.wavURL)
            }
        }

        fputs("[muesli-cli] loading \(request.model.rawValue) and transcribing...\n", stderr)
        let transcription = try await transcriber.transcribe(
            wavURL: prepared.wavURL,
            model: request.model,
            progress: { message in
                fputs("[muesli-cli] \(message)\n", stderr)
            }
        )
        var transcript = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.hasMeaningfulSpeech(transcript) else {
            throw CLIError.invalidInput("No speech was transcribed from the selected audio file.", fix: "Check that the file contains audible speech and try again.")
        }
        if let customWords {
            transcript = CustomWordMatcher.apply(text: transcript, customWords: customWords)
            transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.hasMeaningfulSpeech(transcript) else {
                throw CLIError.invalidInput("No speech remains after applying the selected dictionary.", fix: "Remove dictionary entries that replace all recognized speech with empty text.")
            }
        }

        var warnings: [String] = []
        let title = resolvedTitle(override: request.title, sourceURL: request.sourceURL)
        let duration = transcription.durationSeconds ?? prepared.durationSeconds
        let wordCount = DictationStore.countWords(in: transcript)

        let summary: String?
        if request.summarize {
            do {
                summary = try await summarizer.summarize(transcript: transcript, title: title, supportDirectory: context.supportDirectory)
            } catch {
                let message = "Summary failed: \(error.localizedDescription)"
                warnings.append(message)
                fputs("[muesli-cli] \(message)\n", stderr)
                summary = nil
            }
        } else {
            summary = nil
        }

        let savedMeetingID: Int64?
        if request.saveMeeting {
            try context.store.migrateIfNeeded()
            let savedRecordingPath: String?
            do {
                savedRecordingPath = try persistRecording(sourceURL: request.sourceURL, title: title, supportDirectory: context.supportDirectory)
            } catch {
                let message = "Saving audio copy failed: \(error.localizedDescription)"
                warnings.append(message)
                fputs("[muesli-cli] \(message)\n", stderr)
                savedRecordingPath = nil
            }
            let now = Date()
            let notes = summary ?? Self.rawTranscriptNotes(transcript: transcript, title: title, summaryRequested: request.summarize, warnings: warnings)
            savedMeetingID = try context.store.insertMeeting(
                title: title,
                calendarEventID: nil,
                startTime: now.addingTimeInterval(-max(duration, 0)),
                endTime: now,
                rawTranscript: transcript,
                formattedNotes: notes,
                micAudioPath: nil,
                systemAudioPath: nil,
                savedRecordingPath: savedRecordingPath,
                selectedTemplateID: "cli-audio-import",
                selectedTemplateName: "CLI Audio Import",
                selectedTemplateKind: .custom,
                selectedTemplatePrompt: nil,
                source: .audioImport
            )
            dataChangePoster()
        } else {
            savedMeetingID = nil
        }

        return MuesliAudioTranscriptionResult(
            title: title,
            transcript: transcript,
            summary: summary,
            durationSeconds: duration,
            wordCount: wordCount,
            model: request.model,
            warnings: warnings,
            savedMeetingID: savedMeetingID
        )
    }

    private static func hasMeaningfulSpeech(_ transcript: String) -> Bool {
        transcript.rangeOfCharacter(from: .alphanumerics) != nil
    }

    static func rawTranscriptNotes(transcript: String, title: String, summaryRequested: Bool, warnings: [String]) -> String {
        var sections: [String] = []
        if summaryRequested {
            sections.append("## Summary unavailable")
            if warnings.isEmpty {
                sections.append("Muesli could not generate structured notes from the configured summary backend.")
            } else {
                sections.append(warnings.joined(separator: "\n"))
            }
        } else {
            sections.append("## Summary")
            sections.append("No generated summary was requested.")
        }
        sections.append("## Raw Transcript\n\n\(transcript)")
        return sections.joined(separator: "\n\n")
    }

    /// Loads `--dictionary`'s JSON file: either a plain array of `CustomWord`-shaped
    /// objects, or an object with a `custom_words` key (so a real `config.json`'s
    /// dictionary can be pointed at directly).
    static func loadCustomWords(from url: URL) throws -> [CustomWord] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.notFound("Dictionary file does not exist: \(url.path)", fix: "Pass a JSON array of {word, replacement, matching_threshold} entries.")
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CLIError.invalidInput(
                "Could not read dictionary file \(url.path): \(error.localizedDescription)",
                fix: "Check that the path is a readable file and pass a JSON array of {word, replacement, matching_threshold} entries."
            )
        }
        do {
            return try CustomWordDictionaryCodec.decode(data)
        } catch {
            throw CLIError.invalidInput(
                "Could not parse \(url.path) as a dictionary.",
                fix: "Provide a JSON array of {\"word\": ..., \"replacement\": ..., \"matching_threshold\": ...} objects, or an object with a \"custom_words\" key in that shape."
            )
        }
    }

    private func resolvedTitle(override: String?, sourceURL: URL) -> String {
        let trimmed = override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        let stem = sourceURL.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return stem.isEmpty ? "Imported Audio" : stem
    }

    private func persistRecording(sourceURL: URL, title: String, supportDirectory: URL) throws -> String {
        let recordingsDirectory = supportDirectory.appendingPathComponent("meeting-recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let fileExtension = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "wav"
            : sourceURL.pathExtension.lowercased()
        let filename = "\(formatter.string(from: Date()))_\(safeFilenameComponent(title))_\(UUID().uuidString.prefix(8)).\(fileExtension)"
        let destinationURL = recordingsDirectory.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL.path
    }

    private func safeFilenameComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" })
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
        return collapsed.isEmpty ? "Imported-Audio" : String(collapsed.prefix(80))
    }
}

struct MuesliAudioFilePreparer: AudioPreparing {
    static let supportedExtensions: Set<String> = ["m4a", "mp4", "wav", "mp3"]

    static func isSupportedFileURL(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    enum PreparationError: Error, LocalizedError {
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

    func prepareAudio(sourceURL: URL) async throws -> PreparedAudioFile {
        guard Self.isSupportedFileURL(sourceURL) else {
            throw PreparationError.unsupportedFormat
        }
        try Task.checkCancellation()

        if let compatible = try compatibleWAVInfo(sourceURL: sourceURL) {
            let outputURL = try temporaryWAVURL()
            try FileManager.default.copyItem(at: sourceURL, to: outputURL)
            return PreparedAudioFile(wavURL: outputURL, durationSeconds: compatible.duration, deleteWhenDone: true)
        }

        let duration = try await audioDuration(sourceURL: sourceURL)
        try Task.checkCancellation()

        let decoded = try await decodeAssetReaderToTemporaryWAV(sourceURL: sourceURL)
        guard decoded.sampleCount > 0 else {
            try? FileManager.default.removeItem(at: decoded.wavURL)
            throw PreparationError.noAudioTracks
        }
        let resolvedDuration = duration ?? Double(decoded.sampleCount) / Double(CLIWavWriter.sampleRate)
        guard resolvedDuration > 0, resolvedDuration.isFinite else {
            try? FileManager.default.removeItem(at: decoded.wavURL)
            throw PreparationError.readError("Invalid audio duration.")
        }
        return PreparedAudioFile(wavURL: decoded.wavURL, durationSeconds: resolvedDuration, deleteWhenDone: true)
    }

    private struct CompatibleWAVInfo {
        let duration: TimeInterval
    }

    private func compatibleWAVInfo(sourceURL: URL) throws -> CompatibleWAVInfo? {
        guard sourceURL.pathExtension.lowercased() == "wav" else { return nil }
        let file = try AVAudioFile(forReading: sourceURL)
        let format = file.fileFormat
        guard format.sampleRate == Double(CLIWavWriter.sampleRate),
              format.channelCount == UInt32(CLIWavWriter.channels),
              format.commonFormat == .pcmFormatInt16 else {
            return nil
        }
        let duration = Double(file.length) / format.sampleRate
        guard duration > 0, duration.isFinite else {
            throw PreparationError.readError("Invalid audio duration.")
        }
        return CompatibleWAVInfo(duration: duration)
    }

    private func temporaryWAVURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-cli-import", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("import_\(UUID().uuidString).wav")
    }

    private func audioDuration(sourceURL: URL) async throws -> TimeInterval? {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.load(.tracks)
        guard tracks.contains(where: { $0.mediaType == .audio }) else {
            throw PreparationError.noAudioTracks
        }
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        return duration > 0 && duration.isFinite ? duration : nil
    }

    private func decodeAssetReaderToTemporaryWAV(sourceURL: URL) async throws -> (wavURL: URL, sampleCount: Int) {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.load(.tracks)
        guard let audioTrack = tracks.first(where: { $0.mediaType == .audio }) else {
            throw PreparationError.noAudioTracks
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw PreparationError.conversionFailed("Could not read audio samples from the selected file.")
        }
        reader.add(output)

        guard reader.startReading() else {
            throw PreparationError.readError(reader.error?.localizedDescription ?? "Unknown read error")
        }

        let converter = AudioConverter()
        let wavURL = try CLIWavWriter.temporaryWAVURL(directoryName: "muesli-cli-import")
        do {
            let sampleCount = try CLIWavWriter.writeWAV(to: wavURL) { handle in
                var totalSamples = 0
                while reader.status == .reading {
                    try Task.checkCancellation()
                    guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
                    let chunk = try converter.resampleSampleBuffer(sampleBuffer)
                    totalSamples += try CLIWavWriter.append(samples: chunk, to: handle)
                }
                guard reader.status == .completed else {
                    throw PreparationError.readError(reader.error?.localizedDescription ?? "Read did not complete")
                }
                return totalSamples
            }
            return (wavURL, sampleCount)
        } catch {
            try? FileManager.default.removeItem(at: wavURL)
            throw error
        }
    }
}

/// Dispatches to a per-model-family transcriber. Kept as a thin router so each
/// transcriber stays focused on one inference shape (single-pass FluidAudio
/// `AsrManager` batch, chunked EOU streaming, or a different FluidAudio manager
/// entirely for SenseVoice/Qwen3).
struct RoutingAudioTranscriber: AudioTranscribing {
    var batch: AudioTranscribing = FluidAudioCLITranscriber()
    var parakeetUnified: AudioTranscribing = ParakeetUnifiedCLITranscriber()
    var streaming: AudioTranscribing = StreamingEouCLITranscriber()
    var senseVoice: AudioTranscribing = SenseVoiceCLITranscriber()
    var qwen3Asr: AudioTranscribing = Qwen3AsrCLITranscriber()
    var nemotron35: AudioTranscribing = Nemotron35CLITranscriber()
    var whisper: AudioTranscribing = WhisperCLITranscriber()

    func transcribe(wavURL: URL, model: TranscribeModel, progress: @escaping (String) -> Void) async throws -> HeadlessTranscription {
        let transcriber: AudioTranscribing
        switch model {
        case .parakeetV3, .parakeetV2: transcriber = batch
        case .parakeetUnified: transcriber = parakeetUnified
        case .parakeetEou320ms: transcriber = streaming
        case .senseVoice: transcriber = senseVoice
        case .qwen3Asr: transcriber = qwen3Asr
        case .nemotron35: transcriber = nemotron35
        case .whisperTiny, .whisperTinyEnglish,
             .whisperSmall, .whisperSmallEnglish, .whisperMediumEnglish,
             .whisperLargeTurbo:
            transcriber = whisper
        }
        return try await transcriber.transcribe(wavURL: wavURL, model: model, progress: progress)
    }
}

actor FluidAudioCLITranscriber: AudioTranscribing {
    private var asrManager: AsrManager?
    private var loadedModel: TranscribeModel?

    func transcribe(wavURL: URL, model: TranscribeModel, progress: @escaping (String) -> Void) async throws -> HeadlessTranscription {
        try await load(model: model, progress: progress)
        guard let asrManager else {
            throw CLIError.invalidInput("FluidAudio model was not loaded.", fix: "Run the command again after the model finishes downloading.")
        }
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let result = try await asrManager.transcribe(wavURL, decoderState: &decoderState)
        progress("transcription complete in \(String(format: "%.2f", result.processingTime))s")
        return HeadlessTranscription(
            text: result.text,
            durationSeconds: result.duration > 0 ? result.duration : nil
        )
    }

    private func load(model: TranscribeModel, progress: @escaping (String) -> Void) async throws {
        if loadedModel == model, asrManager != nil { return }
        guard let asrModelVersion = model.asrModelVersion else {
            throw CLIError.invalidInput(
                "\(model.rawValue) is a streaming model and cannot be loaded by the batch transcriber.",
                fix: "This indicates a routing bug in muesli-cli; please file an issue."
            )
        }
        progress("loading \(model.rawValue)")
        let plan = asrModelVersion == .v2
            ? ManagedASRModelPlans.parakeetV2()
            : ManagedASRModelPlans.parakeetV3()
        let manager = try await ManagedASRModelDownloader.loadValidated(
            plan,
            progress: { fraction, message in
                progress(message ?? "model \(Int((fraction * 100).rounded()))%")
            }
        ) { modelDirectory in
            progress("preparing model")
            let models = try await AsrModels.load(from: modelDirectory, version: asrModelVersion)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        asrManager = manager
        loadedModel = model
        progress("model ready")
    }
}

/// Wraps FluidAudio's `SenseVoiceManager` directly — a thin wrapper, same shape as
/// the app's `SenseVoiceTranscriber` (`SenseVoiceBackend.swift`), reusing the app's
/// default model cache. `int8` matches the precision the app selects by default.
actor SenseVoiceCLITranscriber: AudioTranscribing {
    private var manager: SenseVoiceManager?
    private static let precision: SenseVoiceEncoderPrecision = .int8

    func transcribe(wavURL: URL, model: TranscribeModel, progress: @escaping (String) -> Void) async throws -> HeadlessTranscription {
        if manager == nil {
            progress("loading sensevoice")
            let plan = ManagedASRModelPlans.senseVoice()
            manager = try await ManagedASRModelDownloader.loadValidated(
                plan,
                progress: { fraction, message in
                    progress(message ?? "model \(Int((fraction * 100).rounded()))%")
                }
            ) { modelDirectory in
                progress("preparing model")
                let models = try SenseVoiceModels.load(from: modelDirectory, precision: Self.precision)
                return SenseVoiceManager(models: models)
            }
            progress("model ready")
        }
        guard let manager else {
            throw CLIError.invalidInput("SenseVoice model was not loaded.", fix: "Run the command again after the model finishes downloading.")
        }
        let start = CFAbsoluteTimeGetCurrent()
        let text = try await manager.transcribe(audioURL: wavURL)
        progress("transcription complete in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s")
        return HeadlessTranscription(text: text, durationSeconds: nil)
    }
}

/// Wraps the vendored `MuesliQwen3AsrManager` directly — a thin wrapper, same shape as
/// the app's `Qwen3AsrTranscriber` (`Qwen3AsrBackend.swift`), reusing the app's
/// default model cache. Requires macOS 15+ for CoreML stateful decoder support,
/// same constraint the vendored manager itself carries.
actor Qwen3AsrCLITranscriber: AudioTranscribing {
    func transcribe(wavURL: URL, model: TranscribeModel, progress: @escaping (String) -> Void) async throws -> HeadlessTranscription {
        guard #available(macOS 15, *) else {
            throw CLIError.invalidInput("qwen3-asr requires macOS 15 or later.", fix: "Run on macOS 15+, or choose a different --model.")
        }
        return try await transcribeOnSupportedOS(wavURL: wavURL, progress: progress)
    }

    @available(macOS 15, *)
    private func transcribeOnSupportedOS(wavURL: URL, progress: @escaping (String) -> Void) async throws -> HeadlessTranscription {
        if manager == nil {
            progress("loading qwen3-asr")
            let plan = ManagedASRModelPlans.qwen3ASRInt8()
            manager = try await ManagedASRModelDownloader.loadValidated(
                plan,
                progress: { fraction, message in
                    progress(message ?? "model \(Int((fraction * 100).rounded()))%")
                }
            ) { modelDir in
                progress("preparing model")
                let mgr = MuesliQwen3AsrManager()
                try await mgr.loadModels(from: modelDir)
                return mgr
            }
            progress("model ready")
        }
        guard let manager else {
            throw CLIError.invalidInput("Qwen3 ASR model was not loaded.", fix: "Run the command again after the model finishes downloading.")
        }
        let start = CFAbsoluteTimeGetCurrent()
        let samples = try AudioConverter().resampleAudioFile(wavURL)
        guard let qwen3Manager = manager as? MuesliQwen3AsrManager else {
            throw CLIError.invalidInput("Qwen3 ASR model was not loaded.", fix: "Run the command again after the model finishes downloading.")
        }
        let text = try await qwen3Manager.transcribe(audioSamples: samples)
        progress("transcription complete in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s")
        return HeadlessTranscription(text: text, durationSeconds: nil)
    }

    // Stored as Any: the vendored manager is `@available(macOS 15, *)`,
    // and a stored property of that type would force this whole actor declaration behind
    // the same guard — but `RoutingAudioTranscriber` needs to construct this actor
    // unconditionally on any deployment target, and only fail at call time on older OSes.
    private var manager: Any?
}

/// Offline-batch Parakeet Unified 0.6B (FastConformer-RNNT) via the managed
/// model directory shared with the app backend.
actor ParakeetUnifiedCLITranscriber: AudioTranscribing {
    private var manager: UnifiedAsrManager?

    func transcribe(wavURL: URL, model: TranscribeModel, progress: @escaping (String) -> Void) async throws -> HeadlessTranscription {
        if manager == nil {
            progress("loading parakeet-unified")
            let plan = ManagedASRModelPlans.parakeetUnified()
            manager = try await ManagedASRModelDownloader.loadValidated(
                plan,
                progress: { fraction, message in
                    progress(message ?? "model \(Int((fraction * 100).rounded()))%")
                }
            ) { modelDir in
                progress("preparing model")
                let mgr = UnifiedAsrManager()
                try await mgr.loadModels(from: modelDir)
                return mgr
            }
            progress("model ready")
        }
        guard let manager else {
            throw CLIError.invalidInput("Parakeet Unified model was not loaded.", fix: "Run the command again after the model finishes downloading.")
        }
        let start = CFAbsoluteTimeGetCurrent()
        let samples = try AudioConverter().resampleAudioFile(wavURL)
        let text = try await manager.transcribe(samples)
        progress("transcription complete in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s")
        return HeadlessTranscription(text: text, durationSeconds: nil)
    }
}

/// Wraps FluidAudio's public multilingual Nemotron manager using the exact
/// model directory maintained by the app's native Nemotron RNNT backend. The
/// shared store prevents the app and CLI from downloading separate copies.
actor Nemotron35CLITranscriber: AudioTranscribing {
    private var manager: StreamingNemotronMultilingualAsrManager?

    func transcribe(wavURL: URL, model: TranscribeModel, progress: @escaping (String) -> Void) async throws -> HeadlessTranscription {
        let manager = try await loadedManager(progress: progress)
        let start = CFAbsoluteTimeGetCurrent()
        let samples = try AudioConverter().resampleAudioFile(wavURL)
        _ = try await manager.process(samples: samples)
        let text = try await manager.finish()
        await manager.reset()
        progress("transcription complete in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s")
        return HeadlessTranscription(
            text: text,
            durationSeconds: Double(samples.count) / Double(CLIWavWriter.sampleRate)
        )
    }

    private func loadedManager(progress: @escaping (String) -> Void) async throws -> StreamingNemotronMultilingualAsrManager {
        if let manager { return manager }
        progress("loading nemotron35")
        let modelDirectory = try await Nemotron35ModelStore.ensureDownloaded { fraction, message in
            if let message {
                progress(message)
            } else {
                progress("model \(Int((fraction * 100).rounded()))%")
            }
        }
        let shared = try await StreamingNemotronMultilingualAsrManager.preloadShared(from: modelDirectory)
        let newManager = StreamingNemotronMultilingualAsrManager()
        try await newManager.loadFromShared(shared)
        manager = newManager
        progress("model ready")
        return newManager
    }
}

/// Wraps the same WhisperKit API and model cache used by the app's Whisper backend.
actor WhisperCLITranscriber: AudioTranscribing {
    private var whisperKit: WhisperKit?
    private var loadedModel: String?

    func transcribe(wavURL: URL, model: TranscribeModel, progress: @escaping (String) -> Void) async throws -> HeadlessTranscription {
        guard let modelName = model.whisperKitModelName else {
            throw CLIError.invalidInput(
                "\(model.rawValue) is not a Whisper model.",
                fix: "This indicates a routing bug in muesli-cli; please file an issue."
            )
        }
        try await load(modelName: modelName, progress: progress)
        guard let whisperKit else {
            throw CLIError.invalidInput("WhisperKit model was not loaded.", fix: "Run the command again after the model finishes downloading.")
        }
        let start = CFAbsoluteTimeGetCurrent()
        // English-only `.en` checkpoints have no multilingual tokens — keep default DecodingOptions.
        // Multilingual variants need detectLanguage; WhisperKit defaults otherwise force English.
        let decodeOptions: DecodingOptions
        if modelName.hasSuffix(".en") {
            decodeOptions = DecodingOptions()
        } else {
            decodeOptions = DecodingOptions(detectLanguage: true)
        }
        let results = try await whisperKit.transcribe(audioPath: wavURL.path, decodeOptions: decodeOptions)
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        progress("transcription complete in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - start))s")
        return HeadlessTranscription(text: text, durationSeconds: nil)
    }

    private func load(modelName: String, progress: @escaping (String) -> Void) async throws {
        if loadedModel == modelName, whisperKit != nil { return }
        progress("loading \(modelName)")

        let plan = ManagedASRModelPlans.whisperKit(modelName: modelName)
        whisperKit = try await ManagedASRModelDownloader.loadValidated(
            plan,
            progress: { fraction, message in
                progress(message ?? "model \(Int((fraction * 100).rounded()))%")
            }
        ) { modelFolder in
            progress("preparing model")
            return try await WhisperKit(WhisperKitConfig(
                modelFolder: modelFolder.path,
                computeOptions: ModelComputeOptions(
                    audioEncoderCompute: .cpuAndNeuralEngine,
                    textDecoderCompute: .cpuAndNeuralEngine
                )
            ))
        }
        loadedModel = modelName
        progress("model ready")
    }
}

/// Feeds a WAV file through FluidAudio's Parakeet EOU streaming encoder in fixed
/// 320ms chunks, simulating how the live meeting-caption path consumes audio in
/// the app. This is the same model, chunk size, and cache directory as
/// `MeetingLiveCaptionModelStore`/`ParakeetEOUMeetingPartialEngine` in the app
/// target (`MeetingStreamingPartialSession.swift`) — that code lives in an
/// executable target the CLI cannot link, so this reimplements the same call
/// pattern directly against FluidAudio's public streaming API rather than
/// duplicating the app's internal session/tail-state machinery, which the CLI
/// does not need. If a user already downloaded the model via the app's live
/// captions setting, this reuses that same download.
actor StreamingEouCLITranscriber: AudioTranscribing {
    private static let chunkSize = StreamingChunkSize.ms320

    private var manager: StreamingEouAsrManager?

    func transcribe(wavURL: URL, model: TranscribeModel, progress: @escaping (String) -> Void) async throws -> HeadlessTranscription {
        let manager = try await loadedManager(progress: progress)
        let samples = try CLIWavReader.readMonoFloatSamples(url: wavURL)
        guard !samples.isEmpty else {
            return HeadlessTranscription(text: "", durationSeconds: 0)
        }

        let chunkSamples = Self.chunkSize.chunkSamples
        var chunkCount = 0
        var offset = 0
        while offset < samples.count {
            try Task.checkCancellation()
            let end = min(offset + chunkSamples, samples.count)
            var chunk = Array(samples[offset..<end])
            if chunk.count < chunkSamples {
                chunk.append(contentsOf: repeatElement(Float(0), count: chunkSamples - chunk.count))
            }
            guard let buffer = Self.makeBuffer(samples: chunk) else {
                throw CLIError.invalidInput("Could not allocate a streaming audio buffer.", fix: "Try a shorter audio file.")
            }
            chunkCount += 1
            _ = try await manager.process(audioBuffer: buffer)
            offset = end
        }

        let finalText = try await manager.finish()
        progress("streaming transcription complete (\(chunkCount) chunks of \(Self.chunkSize.durationMs)ms)")
        return HeadlessTranscription(
            text: finalText,
            durationSeconds: Double(samples.count) / Double(CLIWavWriter.sampleRate)
        )
    }

    private func loadedManager(progress: @escaping (String) -> Void) async throws -> StreamingEouAsrManager {
        if let manager { return manager }
        let plan = ManagedASRModelPlans.parakeetRealtimeEOU320()
        if !plan.isAvailableLocally() { progress("downloading parakeet-eou-320ms (~430 MB)") }
        progress("loading parakeet-eou-320ms")
        let newManager = try await ManagedASRModelDownloader.loadValidated(
            plan,
            progress: { fraction, message in
                progress(message ?? "model \(Int((fraction * 100).rounded()))%")
            }
        ) { directory in
            let candidate = StreamingEouAsrManager(chunkSize: Self.chunkSize)
            try await candidate.loadModels(from: directory)
            return candidate
        }
        manager = newManager
        progress("model ready")
        return newManager
    }

    private static func makeBuffer(samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        channel.update(from: samples, count: samples.count)
        return buffer
    }
}

/// Reads a prepared CLI WAV (always 16kHz mono, written by `CLIWavWriter`) back into
/// Float32 samples for chunked streaming feed. `AVAudioFile`'s default processing
/// format decodes PCM16 to Float32 automatically, so no manual byte parsing is needed.
enum CLIWavReader {
    static func readMonoFloatSamples(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw CLIError.invalidInput("Could not allocate a read buffer for streaming audio.", fix: "Ensure the prepared audio file is a valid WAV.")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

enum CLIWavWriter {
    static let sampleRate: UInt32 = 16_000
    static let channels: UInt16 = 1
    static let bitsPerSample: UInt16 = 16

    static func temporaryWAVURL(directoryName: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
    }

    static func writeTemporaryWAV(samples: [Float], directoryName: String) throws -> URL {
        let url = try temporaryWAVURL(directoryName: directoryName)
        try writeWAV(samples: samples, to: url)
        return url
    }

    static func writeWAV(samples: [Float], to url: URL) throws {
        _ = try writeWAV(to: url) { handle in
            try append(samples: samples, to: handle)
        }
    }

    @discardableResult
    static func writeWAV(to url: URL, writeSamples: (FileHandle) throws -> Int) throws -> Int {
        _ = FileManager.default.createFile(atPath: url.path, contents: header(dataSize: 0))
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.seekToEnd()
            let sampleCount = try writeSamples(handle)
            let dataSize = UInt32(sampleCount * Int(bitsPerSample / 8))
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: header(dataSize: dataSize))
            try handle.close()
            return sampleCount
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    @discardableResult
    static func append(samples: [Float], to handle: FileHandle) throws -> Int {
        guard !samples.isEmpty else { return 0 }
        var data = Data()
        data.reserveCapacity(samples.count * 2)
        for sample in samples {
            var value = Int16(max(-1.0, min(1.0, sample)) * 32767).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        try handle.write(contentsOf: data)
        return samples.count
    }

    private static func header(dataSize: UInt32) -> Data {
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: (dataSize + 36).littleEndian) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        return header
    }
}

struct ConfiguredCLIMeetingSummarizer: MeetingSummarizing {
    func summarize(transcript: String, title: String, supportDirectory: URL) async throws -> String {
        let config = CLISummaryConfig.load(from: supportDirectory)
        return try await CLISummaryClient.summarize(transcript: transcript, title: title, config: config)
    }
}

struct CLISummaryConfig: Decodable {
    var meetingSummaryBackend = "chatgpt"
    var openAIAPIKey = ""
    var openRouterAPIKey = ""
    var openAIModel = ""
    var openRouterModel = ""
    var ollamaURL = "http://localhost:11434"
    var ollamaModel = "qwen3.5"
    var lmStudioURL = "http://localhost:1234"
    var lmStudioModel = ""
    var customLLMURL = ""
    var customLLMAPIKey = ""
    var customLLMModel = ""
    var customLLMFormat = "openai"

    enum CodingKeys: String, CodingKey {
        case meetingSummaryBackend = "meeting_summary_backend"
        case openAIAPIKey = "openai_api_key"
        case openRouterAPIKey = "openrouter_api_key"
        case openAIModel = "openai_model"
        case openRouterModel = "openrouter_model"
        case ollamaURL = "ollama_url"
        case ollamaModel = "ollama_model"
        case lmStudioURL = "lmstudio_url"
        case lmStudioModel = "lmstudio_model"
        case customLLMURL = "custom_llm_url"
        case customLLMAPIKey = "custom_llm_api_key"
        case customLLMModel = "custom_llm_model"
        case customLLMFormat = "custom_llm_format"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meetingSummaryBackend = try container.decodeIfPresent(String.self, forKey: .meetingSummaryBackend) ?? meetingSummaryBackend
        openAIAPIKey = try container.decodeIfPresent(String.self, forKey: .openAIAPIKey) ?? openAIAPIKey
        openRouterAPIKey = try container.decodeIfPresent(String.self, forKey: .openRouterAPIKey) ?? openRouterAPIKey
        openAIModel = try container.decodeIfPresent(String.self, forKey: .openAIModel) ?? openAIModel
        openRouterModel = try container.decodeIfPresent(String.self, forKey: .openRouterModel) ?? openRouterModel
        ollamaURL = try container.decodeIfPresent(String.self, forKey: .ollamaURL) ?? ollamaURL
        ollamaModel = try container.decodeIfPresent(String.self, forKey: .ollamaModel) ?? ollamaModel
        lmStudioURL = try container.decodeIfPresent(String.self, forKey: .lmStudioURL) ?? lmStudioURL
        lmStudioModel = try container.decodeIfPresent(String.self, forKey: .lmStudioModel) ?? lmStudioModel
        customLLMURL = try container.decodeIfPresent(String.self, forKey: .customLLMURL) ?? customLLMURL
        customLLMAPIKey = try container.decodeIfPresent(String.self, forKey: .customLLMAPIKey) ?? customLLMAPIKey
        customLLMModel = try container.decodeIfPresent(String.self, forKey: .customLLMModel) ?? customLLMModel
        customLLMFormat = try container.decodeIfPresent(String.self, forKey: .customLLMFormat) ?? customLLMFormat
    }

    static func load(from supportDirectory: URL) -> CLISummaryConfig {
        let url = supportDirectory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              var config = try? JSONDecoder().decode(CLISummaryConfig.self, from: data) else {
            return CLISummaryConfig()
        }
        if config.openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            struct StoredOpenRouterCredential: Decodable {
                let apiKey: String

                enum CodingKeys: String, CodingKey {
                    case apiKey = "api_key"
                }
            }
            let credentialURL = supportDirectory.appendingPathComponent("openrouter-auth.json")
            if let credentialData = try? Data(contentsOf: credentialURL),
               let credential = try? JSONDecoder().decode(StoredOpenRouterCredential.self, from: credentialData) {
                config.openRouterAPIKey = credential.apiKey
            }
        }
        return config
    }
}

enum CLISummaryError: LocalizedError {
    case unavailable(String)
    case backendFailed(String)
    case emptyResponse(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .backendFailed(let message), .emptyResponse(let message):
            return message
        }
    }
}

enum CLISummaryClient {
    private static let defaultOpenAIModel = "gpt-5.4-mini"
    private static let defaultOpenRouterModel = "stepfun/step-3.5-flash:free"
    private static let defaultSummaryMaxOutputTokens = 2500

    static func summarize(transcript: String, title: String, config: CLISummaryConfig) async throws -> String {
        let backend = config.meetingSummaryBackend.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch backend.isEmpty ? "chatgpt" : backend {
        case "openai":
            let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? config.openAIAPIKey
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLISummaryError.unavailable("OpenAI summary settings are missing an API key.")
            }
            return try await responsesSummary(
                backend: "OpenAI",
                url: URL(string: "https://api.openai.com/v1/responses")!,
                apiKey: key,
                model: config.openAIModel.isEmpty ? defaultOpenAIModel : config.openAIModel,
                transcript: transcript,
                title: title
            )
        case "openrouter":
            let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? config.openRouterAPIKey
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLISummaryError.unavailable("OpenRouter summary settings are missing an API key.")
            }
            return try await chatCompletionsSummary(
                backend: "OpenRouter",
                url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
                apiKey: key,
                model: config.openRouterModel.isEmpty ? defaultOpenRouterModel : config.openRouterModel,
                transcript: transcript,
                title: title
            )
        case "ollama":
            let baseURL = URL(string: config.ollamaURL.isEmpty ? "http://localhost:11434" : config.ollamaURL)
            guard let baseURL else { throw CLISummaryError.unavailable("Invalid Ollama URL.") }
            return try await ollamaSummary(
                url: baseURL.appendingPathComponent("api/chat"),
                model: config.ollamaModel.isEmpty ? "qwen3.5" : config.ollamaModel,
                transcript: transcript,
                title: title
            )
        case "lmstudio":
            guard !config.lmStudioModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLISummaryError.unavailable("LM Studio summary settings are missing a selected model.")
            }
            guard let url = resolveEndpointURL(config.lmStudioURL.isEmpty ? "http://localhost:1234" : config.lmStudioURL, endpointSuffix: "v1/chat/completions") else {
                throw CLISummaryError.unavailable("Invalid LM Studio URL.")
            }
            return try await chatCompletionsSummary(
                backend: "LM Studio",
                url: url,
                apiKey: "",
                model: config.lmStudioModel,
                transcript: transcript,
                title: title
            )
        case "custom_llm":
            guard !config.customLLMModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLISummaryError.unavailable("Custom LLM summary settings are missing a selected model.")
            }
            if config.customLLMFormat == "anthropic" {
                guard !config.customLLMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLISummaryError.unavailable("Custom Anthropic summary settings are missing an API key.")
                }
                guard let url = resolveEndpointURL(config.customLLMURL.isEmpty ? "https://api.anthropic.com" : config.customLLMURL, endpointSuffix: "v1/messages") else {
                    throw CLISummaryError.unavailable("Invalid Custom LLM URL.")
                }
                return try await anthropicSummary(url: url, apiKey: config.customLLMAPIKey, model: config.customLLMModel, transcript: transcript, title: title)
            }
            guard let url = resolveEndpointURL(config.customLLMURL.isEmpty ? "http://localhost:8080" : config.customLLMURL, endpointSuffix: "v1/chat/completions") else {
                throw CLISummaryError.unavailable("Invalid Custom LLM URL.")
            }
            return try await chatCompletionsSummary(
                backend: "Custom LLM",
                url: url,
                apiKey: config.customLLMAPIKey,
                model: config.customLLMModel,
                transcript: transcript,
                title: title
            )
        default:
            throw CLISummaryError.unavailable("The configured ChatGPT session summary backend is app-only in headless CLI mode. Select OpenAI, OpenRouter, Ollama, LM Studio, or Custom LLM in Muesli settings for `muesli-cli transcribe --summarize`.")
        }
    }

    private static func systemPrompt() -> String {
        """
        You are a meeting notes assistant. Given a raw meeting transcript, produce concise, professional markdown notes.
        Do not invent facts. Prefer concrete takeaways over filler. Capture owners only when they are actually mentioned.
        If a requested section has no content, write "None noted."

        Follow this markdown template:

        ## Summary
        - Main points

        ## Decisions
        - Decisions made

        ## Action Items
        - Owner: task
        """
    }

    private static func userPrompt(transcript: String, title: String) -> String {
        "Meeting title: \(title)\n\nRaw transcript:\n\(transcript)"
    }

    private static func responsesSummary(backend: String, url: URL, apiKey: String, model: String, transcript: String, title: String) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "input": [
                ["role": "system", "content": systemPrompt()],
                ["role": "user", "content": userPrompt(transcript: transcript, title: title)],
            ],
            "reasoning": ["effort": "low"],
            "text": ["verbosity": "low"],
            "max_output_tokens": defaultSummaryMaxOutputTokens,
        ]
        let data = try await postJSON(url: url, apiKey: apiKey, body: body, backend: backend)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = extractOpenAIText(from: json),
              !text.isEmpty else {
            throw CLISummaryError.emptyResponse("\(backend) returned an empty summary response.")
        }
        return text
    }

    private static func chatCompletionsSummary(backend: String, url: URL, apiKey: String, model: String, transcript: String, title: String) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt()],
                ["role": "user", "content": userPrompt(transcript: transcript, title: title)],
            ],
            "max_tokens": defaultSummaryMaxOutputTokens,
        ]
        let data = try await postJSON(url: url, apiKey: apiKey, body: body, backend: backend)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = extractChatCompletionsText(from: json),
              !text.isEmpty else {
            throw CLISummaryError.emptyResponse("\(backend) returned an empty summary response.")
        }
        return text
    }

    private static func ollamaSummary(url: URL, model: String, transcript: String, title: String) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt()],
                ["role": "user", "content": userPrompt(transcript: transcript, title: title)],
            ],
            "stream": false,
            "options": ["num_predict": defaultSummaryMaxOutputTokens],
        ]
        let data = try await postJSON(url: url, apiKey: "", body: body, backend: "Ollama")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let text = message["content"] as? String,
              !text.isEmpty else {
            throw CLISummaryError.emptyResponse("Ollama returned an empty summary response.")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func anthropicSummary(url: URL, apiKey: String, model: String, transcript: String, title: String) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": defaultSummaryMaxOutputTokens,
            "system": systemPrompt(),
            "messages": [
                ["role": "user", "content": userPrompt(transcript: transcript, title: title)],
            ],
        ]
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(request: request, backend: "Custom LLM")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw CLISummaryError.emptyResponse("Custom LLM returned an empty summary response.")
        }
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw CLISummaryError.emptyResponse("Custom LLM returned an empty summary response.")
        }
        return text
    }

    private static func postJSON(url: URL, apiKey: String, body: [String: Any], backend: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request: request, backend: backend)
    }

    private static func send(request: URLRequest, backend: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = extractErrorMessage(from: data)
                ?? String(data: data, encoding: .utf8)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw CLISummaryError.backendFailed("\(backend) summary failed with HTTP \(http.statusCode): \(String(message.prefix(500)))")
        }
        return data
    }

    private static func extractOpenAIText(from payload: [String: Any]) -> String? {
        if let outputText = payload["output_text"] as? String, !outputText.isEmpty {
            return outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let output = payload["output"] as? [[String: Any]] ?? []
        for item in output where (item["type"] as? String) == "message" {
            let content = item["content"] as? [[String: Any]] ?? []
            for entry in content {
                if let text = entry["text"] as? String, !text.isEmpty {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
    }

    private static func extractChatCompletionsText(from payload: [String: Any]) -> String? {
        let choices = payload["choices"] as? [[String: Any]] ?? []
        guard let message = choices.first?["message"] as? [String: Any] else { return nil }
        if let content = message["content"] as? String, !content.isEmpty {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any] {
            return error["message"] as? String ?? error["code"] as? String ?? String(describing: error)
        }
        return json["message"] as? String ?? json["detail"] as? String
    }

    private static func resolveEndpointURL(_ rawURL: String, endpointSuffix: String) -> URL? {
        guard var components = URLComponents(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme != nil,
              components.host != nil else {
            return nil
        }
        let suffixParts = endpointSuffix.split(separator: "/").map(String.init)
        var pathParts = components.path.split(separator: "/").map(String.init)
        if pathParts.isEmpty {
            pathParts = suffixParts
        } else if pathParts.last == suffixParts.first {
            pathParts = Array(pathParts.dropLast()) + suffixParts
        } else if !isCompleteEndpointPath(pathParts, endpointSuffixParts: suffixParts) {
            pathParts.append(contentsOf: suffixParts)
        }
        components.path = "/" + pathParts.joined(separator: "/")
        return components.url
    }

    private static func isCompleteEndpointPath(_ pathParts: [String], endpointSuffixParts suffixParts: [String]) -> Bool {
        if pathParts.suffix(suffixParts.count).elementsEqual(suffixParts) {
            return true
        }
        if suffixParts == ["v1", "chat", "completions"] {
            return pathParts.suffix(2).elementsEqual(["chat", "completions"])
        }
        if suffixParts == ["v1", "messages"] {
            return pathParts.count >= suffixParts.count && pathParts.last == "messages"
        }
        return false
    }
}
