import Foundation
import Testing
import MuesliCore
@testable import MuesliCLI

@Suite("MuesliCLI", .serialized)
struct MuesliCLITests {
    @Test("spec exposes the agent-facing command set")
    func specPayloadIncludesCommands() {
        let payload = MuesliCLI.specPayload()
        let names = Set(payload.commands.map(\.name))

        #expect(names.contains("spec"))
        #expect(names.contains("info"))
        #expect(names.contains("transcribe"))
        #expect(names.contains("meetings list"))
        #expect(names.contains("meetings get"))
        #expect(names.contains("meetings update-notes"))
        #expect(names.contains("dictations list"))
        #expect(names.contains("dictations get"))

        let transcribeSpec = payload.commands.first { $0.name == "transcribe" }
        #expect(transcribeSpec?.usage.contains("nemotron35") == true)
        #expect(transcribeSpec?.usage.contains("--dictionary") == true)
    }

    @Test("explicit db path overrides support directory resolution")
    func cliContextUsesExplicitDatabasePath() {
        let context = CLIContext(
            dbPath: "/tmp/custom-muesli.db",
            supportDir: "/tmp/ignored-support"
        )

        #expect(context.databaseURL.path == "/tmp/custom-muesli.db")
        #expect(context.supportDirectory.path == "/tmp/ignored-support")
    }

    @Test("explicit support dir resolves the default db name inside it")
    func cliContextUsesExplicitSupportDirectory() {
        let context = CLIContext(
            dbPath: nil,
            supportDir: "/tmp/muesli-support"
        )

        #expect(context.supportDirectory.path == "/tmp/muesli-support")
        #expect(context.databaseURL.path == "/tmp/muesli-support/muesli.db")
    }

    @Test("meeting payloads expose applied template metadata")
    func meetingPayloadIncludesTemplateMetadata() {
        let record = MeetingRecord(
            id: 42,
            title: "Weekly Sync",
            startTime: "2026-03-22T10:00:00Z",
            durationSeconds: 1800,
            rawTranscript: "Transcript",
            formattedNotes: "## Summary",
            wordCount: 120,
            folderID: nil,
            selectedTemplateID: "weekly-team-meeting",
            selectedTemplateName: "Weekly Team Meeting",
            selectedTemplateKind: .builtin,
            selectedTemplatePrompt: "## Weekly Overview"
        )

        let listRow = MeetingListRow(record)
        let detailPayload = MeetingDetailPayload(record)

        #expect(listRow.selectedTemplateID == "weekly-team-meeting")
        #expect(listRow.selectedTemplateName == "Weekly Team Meeting")
        #expect(listRow.selectedTemplateKind == "builtin")
        #expect(detailPayload.selectedTemplatePrompt == "## Weekly Overview")
    }

    @Test("transcribe validation rejects unsupported file extensions")
    func transcribeRejectsUnsupportedExtension() {
        #expect(throws: Error.self) {
            _ = try TranscribeCommand.parse(["recording.aiff"])
        }
    }

    @Test("transcribe enums accept documented model and format values")
    func transcribeEnumsAcceptDocumentedValues() {
        #expect(TranscribeModel(argument: "parakeet-v3") == .parakeetV3)
        #expect(TranscribeModel(argument: "parakeet-v2") == .parakeetV2)
        #expect(TranscribeModel(argument: "parakeet-eou-320ms") == .parakeetEou320ms)
        #expect(TranscribeModel(argument: "sensevoice") == .senseVoice)
        #expect(TranscribeModel(argument: "qwen3-asr") == .qwen3Asr)
        #expect(TranscribeModel(argument: "nemotron35") == .nemotron35)
        #expect(TranscribeModel(argument: "whisper-tiny") == .whisperTiny)
        #expect(TranscribeModel(argument: "whisper-tiny-english") == .whisperTinyEnglish)
        #expect(TranscribeModel(argument: "whisper-small") == .whisperSmall)
        #expect(TranscribeModel(argument: "whisper-small-english") == .whisperSmallEnglish)
        #expect(TranscribeModel(argument: "whisper-medium-english") == .whisperMediumEnglish)
        #expect(TranscribeModel(argument: "whisper-large-turbo") == .whisperLargeTurbo)
        #expect(TranscribeModel.nemotron35.asrModelVersion == nil)
        #expect(TranscribeModel.whisperTiny.whisperKitModelName == "tiny")
        #expect(TranscribeModel.whisperTinyEnglish.whisperKitModelName == "tiny.en")
        #expect(TranscribeModel.whisperSmall.whisperKitModelName == "small")
        #expect(TranscribeModel.whisperSmallEnglish.whisperKitModelName == "small.en")
        #expect(TranscribeModel.whisperMediumEnglish.whisperKitModelName == "medium.en")
        #expect(TranscribeModel.whisperLargeTurbo.whisperKitModelName == "large-v3-v20240930_626MB")
        #expect(TranscribeModel(argument: "whisper-medium") == nil)
        #expect(TranscribeModel(argument: "canary-qwen") == nil)
        #expect(TranscribeOutputFormat(argument: "text") == .text)
        #expect(TranscribeOutputFormat(argument: "json") == .json)
        #expect(TranscribeOutputFormat(argument: "markdown") == .markdown)
        #expect(TranscribeOutputFormat(argument: "xml") == nil)
    }

    @Test("--dictionary parses into the request")
    func dictionaryOptionParses() throws {
        let command = try TranscribeCommand.parse(["recording.wav", "--dictionary", "/tmp/dictionary.json"])
        #expect(command.dictionary == "/tmp/dictionary.json")
    }

    @Test("loadCustomWords accepts a plain JSON array")
    func loadCustomWordsAcceptsPlainArray() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-cli-dictionary-\(UUID().uuidString).json")
        try Data("""
        [{"word": "museli", "replacement": "muesli", "matching_threshold": 0.85}]
        """.utf8).write(to: url)

        let words = try MuesliAudioTranscriptionPipeline.loadCustomWords(from: url)
        #expect(words.count == 1)
        #expect(words[0].word == "museli")
        #expect(words[0].targetWord == "muesli")
    }

    @Test("loadCustomWords accepts a config.json-shaped object")
    func loadCustomWordsAcceptsConfigShape() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-cli-dictionary-\(UUID().uuidString).json")
        try Data("""
        {"custom_words": [{"word": "kubernete", "replacement": "Kubernetes"}], "other_config_key": true}
        """.utf8).write(to: url)

        let words = try MuesliAudioTranscriptionPipeline.loadCustomWords(from: url)
        #expect(words.count == 1)
        #expect(words[0].targetWord == "Kubernetes")
    }

    @Test("loadCustomWords rejects a missing file")
    func loadCustomWordsRejectsMissingFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        #expect(throws: Error.self) {
            _ = try MuesliAudioTranscriptionPipeline.loadCustomWords(from: url)
        }
    }

    @Test("loadCustomWords distinguishes unreadable paths from missing files")
    func loadCustomWordsRejectsUnreadablePath() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-cli-dictionary-directory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

        do {
            _ = try MuesliAudioTranscriptionPipeline.loadCustomWords(from: url)
            Issue.record("Expected reading a directory as a dictionary to fail")
        } catch let error as CLIError {
            #expect(error.errorBody.code == "invalid_input")
            #expect(error.errorBody.message.contains("Could not read dictionary file"))
        }
    }

    @Test("pipeline validates the dictionary before transcription")
    func pipelineValidatesDictionaryBeforeTranscription() async throws {
        let fixture = try TranscribeFixture()
        let missingDictionaryURL = fixture.directory.appendingPathComponent("missing-dictionary.json")
        let pipeline = MuesliAudioTranscriptionPipeline(
            audioPreparer: FakeAudioPreparer(wavURL: fixture.wavURL, durationSeconds: 3),
            transcriber: FailingTranscriber(),
            summarizer: SuccessfulSummarizer(notes: "should not run"),
            dataChangePoster: {}
        )

        do {
            _ = try await pipeline.run(
                request: MuesliAudioTranscriptionRequest(
                    sourceURL: fixture.sourceURL,
                    model: .parakeetV3,
                    title: "Fail Fast Demo",
                    summarize: false,
                    saveMeeting: false,
                    dictionaryURL: missingDictionaryURL
                ),
                context: fixture.context
            )
            Issue.record("Expected the missing dictionary to fail before transcription")
        } catch let error as CLIError {
            #expect(error.errorBody.code == "not_found")
        }
    }

    @Test("pipeline applies the dictionary to the transcript")
    func pipelineAppliesDictionary() async throws {
        let fixture = try TranscribeFixture()
        let dictionaryURL = fixture.directory.appendingPathComponent("dictionary.json")
        try Data("""
        [{"word": "museli", "replacement": "muesli"}]
        """.utf8).write(to: dictionaryURL)

        let pipeline = MuesliAudioTranscriptionPipeline(
            audioPreparer: FakeAudioPreparer(wavURL: fixture.wavURL, durationSeconds: 3),
            transcriber: FakeTranscriber(text: "I love museli"),
            summarizer: SuccessfulSummarizer(notes: "unused"),
            dataChangePoster: {}
        )

        let result = try await pipeline.run(
            request: MuesliAudioTranscriptionRequest(
                sourceURL: fixture.sourceURL,
                model: .parakeetV3,
                title: "Dictionary Demo",
                summarize: false,
                saveMeeting: false,
                dictionaryURL: dictionaryURL
            ),
            context: fixture.context
        )

        #expect(result.transcript == "I love muesli")
    }

    @Test("pipeline rejects a dictionary that removes the entire transcript")
    func pipelineRejectsDictionaryEmptiedTranscript() async throws {
        let fixture = try TranscribeFixture()
        let dictionaryURL = fixture.directory.appendingPathComponent("empty-dictionary.json")
        try Data("""
        [{"word": "hello", "replacement": ""}]
        """.utf8).write(to: dictionaryURL)

        let pipeline = MuesliAudioTranscriptionPipeline(
            audioPreparer: FakeAudioPreparer(wavURL: fixture.wavURL, durationSeconds: 3),
            transcriber: FakeTranscriber(text: "hello"),
            summarizer: SuccessfulSummarizer(notes: "should not run"),
            dataChangePoster: {}
        )

        do {
            _ = try await pipeline.run(
                request: MuesliAudioTranscriptionRequest(
                    sourceURL: fixture.sourceURL,
                    model: .parakeetV3,
                    title: "Empty Dictionary Demo",
                    summarize: true,
                    saveMeeting: true,
                    dictionaryURL: dictionaryURL
                ),
                context: fixture.context
            )
            Issue.record("Expected the post-dictionary empty transcript to be rejected")
        } catch let error as CLIError {
            #expect(error.errorBody.code == "invalid_input")
            #expect(error.errorBody.message.contains("No speech remains"))
        }
    }

    @Test("pipeline rejects a dictionary that leaves only punctuation")
    func pipelineRejectsDictionaryPunctuationOnlyTranscript() async throws {
        let fixture = try TranscribeFixture()
        let dictionaryURL = fixture.directory.appendingPathComponent("punctuation-dictionary.json")
        try Data("""
        [{"word": "hello", "replacement": ""}]
        """.utf8).write(to: dictionaryURL)

        let pipeline = MuesliAudioTranscriptionPipeline(
            audioPreparer: FakeAudioPreparer(wavURL: fixture.wavURL, durationSeconds: 3),
            transcriber: FakeTranscriber(text: "hello!"),
            summarizer: SuccessfulSummarizer(notes: "should not run"),
            dataChangePoster: {}
        )

        do {
            _ = try await pipeline.run(
                request: MuesliAudioTranscriptionRequest(
                    sourceURL: fixture.sourceURL,
                    model: .parakeetV3,
                    title: "Punctuation Dictionary Demo",
                    summarize: true,
                    saveMeeting: true,
                    dictionaryURL: dictionaryURL
                ),
                context: fixture.context
            )
            Issue.record("Expected a punctuation-only post-dictionary transcript to be rejected")
        } catch let error as CLIError {
            #expect(error.errorBody.code == "invalid_input")
            #expect(error.errorBody.message.contains("No speech remains"))
        }
    }

    @Test("transcribe text output is transcript only")
    func transcribeTextOutputIsTranscriptOnly() throws {
        let result = MuesliAudioTranscriptionResult(
            title: "Demo",
            transcript: "hello from muesli",
            summary: nil,
            durationSeconds: 2,
            wordCount: 3,
            model: .parakeetV3,
            warnings: [],
            savedMeetingID: nil
        )

        #expect(result.textOutput == "hello from muesli\n")
    }

    @Test("transcribe markdown output includes title summary and transcript")
    func transcribeMarkdownOutputIncludesSections() throws {
        let result = MuesliAudioTranscriptionResult(
            title: "Demo",
            transcript: "hello from muesli",
            summary: "## Summary\n\n- Done",
            durationSeconds: 2,
            wordCount: 3,
            model: .parakeetV3,
            warnings: [],
            savedMeetingID: nil
        )

        #expect(result.markdownOutput == """
        # Demo

        ## Summary

        - Done

        ## Raw Transcript

        hello from muesli
        """)
    }

    @Test("transcribe json payload follows CLI envelope")
    func transcribeJSONPayloadUsesEnvelope() throws {
        let payload = TranscribeJSONPayload(
            MuesliAudioTranscriptionResult(
                title: "Demo",
                transcript: "hello from muesli",
                summary: "## Summary\n\n- Done",
                durationSeconds: 4,
                wordCount: 3,
                model: .parakeetV2,
                warnings: ["summary warning"],
                savedMeetingID: 12
            )
        )
        let envelope = SuccessEnvelope(
            command: "muesli-cli transcribe",
            data: payload,
            meta: MetaBody(schemaVersion: 1, generatedAt: "2026-07-08T00:00:00Z", dbPath: "/tmp/muesli.db", warnings: ["summary warning"])
        )
        let data = try encodedJSON(envelope)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["ok"] as? Bool == true)
        #expect(json["command"] as? String == "muesli-cli transcribe")
        let payloadData = try #require(json["data"] as? [String: Any])
        #expect(payloadData["transcript"] as? String == "hello from muesli")
        #expect(payloadData["model"] as? String == "parakeet-v2")
        #expect(payloadData["savedMeetingID"] as? Int == 12)
        #expect(payloadData["summary"] as? String == "## Summary\n\n- Done")

        let nilPayload = TranscribeJSONPayload(
            MuesliAudioTranscriptionResult(
                title: "No Summary",
                transcript: "raw only",
                summary: nil,
                durationSeconds: 2,
                wordCount: 2,
                model: .parakeetV3,
                warnings: [],
                savedMeetingID: nil
            )
        )
        let nilData = try encodedJSON(nilPayload)
        let nilJSON = try #require(JSONSerialization.jsonObject(with: nilData) as? [String: Any])
        #expect(nilJSON.keys.contains("summary"))
        #expect(nilJSON["summary"] is NSNull)
        #expect(nilJSON.keys.contains("savedMeetingID"))
        #expect(nilJSON["savedMeetingID"] is NSNull)
    }

    @Test("transcribe summary failure keeps transcript with warning")
    func transcribeSummaryFailureKeepsTranscript() async throws {
        let fixture = try TranscribeFixture()
        let pipeline = MuesliAudioTranscriptionPipeline(
            audioPreparer: FakeAudioPreparer(wavURL: fixture.wavURL, durationSeconds: 3),
            transcriber: FakeTranscriber(text: "important transcript"),
            summarizer: FailingSummarizer(),
            dataChangePoster: {}
        )

        let result = try await pipeline.run(
            request: MuesliAudioTranscriptionRequest(
                sourceURL: fixture.sourceURL,
                model: .parakeetV3,
                title: "Failure Demo",
                summarize: true,
                saveMeeting: false
            ),
            context: fixture.context
        )

        #expect(result.transcript == "important transcript")
        #expect(result.summary == nil)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].contains("Summary failed"))
    }

    @Test("transcribe save meeting inserts audio import and posts data change")
    func transcribeSaveMeetingInsertsAudioImport() async throws {
        let fixture = try TranscribeFixture()
        var posted = 0
        let pipeline = MuesliAudioTranscriptionPipeline(
            audioPreparer: FakeAudioPreparer(wavURL: fixture.wavURL, durationSeconds: 5),
            transcriber: FakeTranscriber(text: "save this imported meeting"),
            summarizer: SuccessfulSummarizer(notes: "## Summary\n\n- Saved"),
            dataChangePoster: { posted += 1 }
        )

        let result = try await pipeline.run(
            request: MuesliAudioTranscriptionRequest(
                sourceURL: fixture.sourceURL,
                model: .parakeetV3,
                title: "Saved Import",
                summarize: true,
                saveMeeting: true
            ),
            context: fixture.context
        )

        let id = try #require(result.savedMeetingID)
        let meeting = try #require(try fixture.context.store.meeting(id: id))
        #expect(meeting.title == "Saved Import")
        #expect(meeting.rawTranscript == "save this imported meeting")
        #expect(meeting.formattedNotes == "## Summary\n\n- Saved")
        #expect(meeting.source == .audioImport)
        let savedRecordingPath = try #require(meeting.savedRecordingPath)
        #expect(FileManager.default.fileExists(atPath: savedRecordingPath))
        #expect(URL(fileURLWithPath: savedRecordingPath).pathExtension == fixture.sourceURL.pathExtension)
        #expect(posted == 1)
    }

    @Test("transcribe output writes file content")
    func transcribeOutputWritesFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-cli-output-\(UUID().uuidString)", isDirectory: true)
        let outputURL = directory.appendingPathComponent("transcript.txt")
        try writeOutput("plain transcript\n", to: outputURL)

        #expect(try String(contentsOf: outputURL, encoding: .utf8) == "plain transcript\n")
    }
}

private struct TranscribeFixture {
    let directory: URL
    let sourceURL: URL
    let wavURL: URL
    let context: CLIContext

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-cli-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sourceURL = directory.appendingPathComponent("recording.wav")
        wavURL = directory.appendingPathComponent("prepared.wav")
        let samples = Array(repeating: Float(0.1), count: 16_000)
        try CLIWavWriter.writeWAV(samples: samples, to: sourceURL)
        try CLIWavWriter.writeWAV(samples: samples, to: wavURL)
        context = CLIContext(
            dbPath: directory.appendingPathComponent("muesli.db").path,
            supportDir: directory.path
        )
    }
}

private struct FakeAudioPreparer: AudioPreparing {
    let wavURL: URL
    let durationSeconds: Double

    func prepareAudio(sourceURL: URL) async throws -> PreparedAudioFile {
        PreparedAudioFile(wavURL: wavURL, durationSeconds: durationSeconds, deleteWhenDone: false)
    }
}

private struct FakeTranscriber: AudioTranscribing {
    let text: String

    func transcribe(wavURL: URL, model: TranscribeModel, progress: @escaping (String) -> Void) async throws -> HeadlessTranscription {
        progress("fake")
        return HeadlessTranscription(text: text, durationSeconds: nil)
    }
}

private struct FailingTranscriber: AudioTranscribing {
    func transcribe(wavURL: URL, model: TranscribeModel, progress: @escaping (String) -> Void) async throws -> HeadlessTranscription {
        throw CLIError.invalidInput("Transcription should not run when dictionary validation fails.")
    }
}

private struct SuccessfulSummarizer: MeetingSummarizing {
    let notes: String

    func summarize(transcript: String, title: String, supportDirectory: URL) async throws -> String {
        notes
    }
}

private struct FailingSummarizer: MeetingSummarizing {
    func summarize(transcript: String, title: String, supportDirectory: URL) async throws -> String {
        throw CLISummaryError.unavailable("summary backend unavailable")
    }
}
