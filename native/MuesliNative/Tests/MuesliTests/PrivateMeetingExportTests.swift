import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("Private meeting auto-export")
struct PrivateMeetingExportTests {

    private func makeMeeting() -> MeetingRecord {
        MeetingRecord(
            id: 7,
            title: "Counsel call",
            startTime: "2026-04-14T10:00:00Z",
            durationSeconds: 1800,
            rawTranscript: "Privileged discussion",
            formattedNotes: "## Key Points\n- Settlement terms",
            wordCount: 2,
            folderID: nil
        )
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-private-export-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func enabledConfig(destination: URL) -> AppConfig {
        var config = AppConfig()
        config.autoExportMarkdownEnabled = true
        config.autoExportMarkdownFolderPath = destination.path
        return config
    }

    @Test("a private meeting writes nothing and logs why")
    func privateMeetingIsNotExported() async throws {
        let support = makeTemporaryDirectory()
        let destination = makeTemporaryDirectory()
        let exporter = MeetingMarkdownAutoExporter(supportDirectory: support)

        let result = await exporter.performExport(
            meeting: makeMeeting(),
            config: enabledConfig(destination: destination),
            isPrivateMeeting: true
        )
        exporter.waitForPendingLogWrites()

        #expect(result == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        let log = try String(contentsOf: exporter.logURL, encoding: .utf8)
        #expect(log.contains("private meeting id=7"))
    }

    @Test("a private meeting does not create the destination folder either")
    func privateMeetingDoesNotTouchDestination() async throws {
        let support = makeTemporaryDirectory()
        let destination = makeTemporaryDirectory().appendingPathComponent("not-yet-created")
        let exporter = MeetingMarkdownAutoExporter(supportDirectory: support)

        _ = await exporter.performExport(
            meeting: makeMeeting(),
            config: enabledConfig(destination: destination),
            isPrivateMeeting: true
        )

        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }

    @Test("exportIfConfigured honors the private flag")
    func exportIfConfiguredSkipsPrivate() async throws {
        let support = makeTemporaryDirectory()
        let destination = makeTemporaryDirectory()
        let exporter = MeetingMarkdownAutoExporter(supportDirectory: support)

        exporter.exportIfConfigured(
            meeting: makeMeeting(),
            config: enabledConfig(destination: destination),
            isPrivateMeeting: true
        )
        try await Task.sleep(nanoseconds: 300_000_000)
        exporter.waitForPendingLogWrites()

        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test("a normal meeting still exports")
    func normalMeetingStillExports() async throws {
        let support = makeTemporaryDirectory()
        let destination = makeTemporaryDirectory()
        let exporter = MeetingMarkdownAutoExporter(supportDirectory: support)

        let url = await exporter.performExport(
            meeting: makeMeeting(),
            config: enabledConfig(destination: destination),
            isPrivateMeeting: false
        )?.first

        #expect(url != nil)
    }
}
