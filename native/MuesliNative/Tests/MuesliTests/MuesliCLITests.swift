import Foundation
import Testing
import MuesliCore
@testable import MuesliCLI

@Suite("MuesliCLI", .serialized)
struct MuesliCLITests {
    @Test("spec exposes the agent-facing command set")
    func specPayloadIncludesCommands() {
        let names = Set(MuesliCLI.specPayload().commands.map(\.name))

        #expect(names.contains("spec"))
        #expect(names.contains("info"))
        #expect(names.contains("transcribe"))
        #expect(names.contains("meetings list"))
        #expect(names.contains("meetings get"))
        #expect(names.contains("meetings update-notes"))
        #expect(names.contains("dictations list"))
        #expect(names.contains("dictations get"))
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
        #expect(TranscribeModel(argument: "canary-qwen") == nil)
        #expect(TranscribeOutputFormat(argument: "text") == .text)
        #expect(TranscribeOutputFormat(argument: "json") == .json)
        #expect(TranscribeOutputFormat(argument: "markdown") == .markdown)
        #expect(TranscribeOutputFormat(argument: "xml") == nil)
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
