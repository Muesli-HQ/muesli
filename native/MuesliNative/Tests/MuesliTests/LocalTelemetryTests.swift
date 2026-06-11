import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("EventLogWriter")
struct EventLogWriterTests {

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("event-log-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func readLines(_ url: URL) throws -> [[String: Any]] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return try contents.split(separator: "\n").map { line in
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        }
    }

    @Test("writes one JSON line per event")
    func writesOneLinePerEvent() throws {
        let directory = makeTemporaryDirectory()
        let writer = EventLogWriter(directory: directory, isEnabled: true, appVersion: "1.2.3")

        writer.write("app.launched")
        writer.write("dictation.completed", parameters: ["backend": "parakeet", "paste_method": "cmd_v"])
        writer.flush()

        let lines = try readLines(writer.logURL)
        #expect(lines.count == 2)
        #expect(lines[0]["event"] as? String == "app.launched")
        #expect(lines[0]["params"] == nil)
        #expect(lines[0]["app_version"] as? String == "1.2.3")
        #expect(lines[1]["event"] as? String == "dictation.completed")
        let params = lines[1]["params"] as? [String: String]
        #expect(params == ["backend": "parakeet", "paste_method": "cmd_v"])
        #expect(lines.allSatisfy { $0["ts"] is String })
    }

    @Test("disabled writer produces no file")
    func disabledWriterIsNoOp() {
        let directory = makeTemporaryDirectory()
        let writer = EventLogWriter(directory: directory, isEnabled: false)

        writer.write("app.launched")
        writer.flush()

        #expect(FileManager.default.fileExists(atPath: writer.logURL.path) == false)
    }

    @Test("setEnabled toggles logging at runtime")
    func setEnabledTogglesLogging() throws {
        let directory = makeTemporaryDirectory()
        let writer = EventLogWriter(directory: directory, isEnabled: false)

        writer.write("dropped.event")
        writer.setEnabled(true)
        writer.write("kept.event")
        writer.setEnabled(false)
        writer.write("dropped.again")
        writer.flush()

        let events = try readLines(writer.logURL).compactMap { $0["event"] as? String }
        #expect(events == ["kept.event"])
    }

    @Test("creates the log file with owner-only permissions")
    func createsFileWithOwnerOnlyPermissions() throws {
        let directory = makeTemporaryDirectory()
        let writer = EventLogWriter(directory: directory, isEnabled: true)

        writer.write("app.launched")
        writer.flush()

        let attributes = try FileManager.default.attributesOfItem(atPath: writer.logURL.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test("tightens permissions on a pre-existing world-readable log")
    func tightensLoosePermissions() throws {
        let directory = makeTemporaryDirectory()
        let writer = EventLogWriter(directory: directory, isEnabled: true)
        FileManager.default.createFile(
            atPath: writer.logURL.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o644]
        )

        writer.write("app.launched")
        writer.flush()

        let attributes = try FileManager.default.attributesOfItem(atPath: writer.logURL.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test("rotates the log once it reaches the size cap")
    func rotatesAtSizeCap() throws {
        let directory = makeTemporaryDirectory()
        let writer = EventLogWriter(directory: directory, isEnabled: true, maxBytes: 200)

        for index in 0..<10 {
            writer.write("event.\(index)", parameters: ["padding": String(repeating: "x", count: 60)])
        }
        writer.flush()

        // Single rotation slot: the active file stays bounded, the previous
        // generation is kept in events.jsonl.1, and older generations are
        // discarded. The newest event must always be in the active file.
        let rotatedURL = directory.appendingPathComponent("events.jsonl.1")
        #expect(FileManager.default.fileExists(atPath: rotatedURL.path))
        let activeSize = (try FileManager.default.attributesOfItem(atPath: writer.logURL.path))[.size] as? Int
        #expect(activeSize != nil && activeSize! < 400)

        let activeEvents = try readLines(writer.logURL).compactMap { $0["event"] as? String }
        #expect(activeEvents.last == "event.9")
    }

    @Test("creates missing directories")
    func createsMissingDirectories() throws {
        let directory = makeTemporaryDirectory().appendingPathComponent("nested/sub")
        let writer = EventLogWriter(directory: directory, isEnabled: true)

        writer.write("app.launched")
        writer.flush()

        #expect(try readLines(writer.logURL).count == 1)
    }
}
