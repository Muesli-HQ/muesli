import AppKit
import Foundation
import SQLite3
import Testing
@testable import MuesliCLI
@testable import MuesliCore
@testable import MuesliNativeApp

private final class CapturesCLITestBundle: NSObject {}

@Suite("Scrawl CLI", .serialized)
struct CapturesCLITests {
    @Test func lockedLegacyReadsRetainMigrationGuidance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scrawl-migration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = CLIContext(dbPath: nil, supportDir: root.path)
        var db: OpaquePointer?
        try #require(sqlite3_open(context.databaseURL.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        for canRead in [false, true] {
            if canRead {
                // Synthetic legacy table only: the rest of the app schema still needs migration.
                try #require(sqlite3_exec(db, "CREATE TABLE feedback_captures(id TEXT, created_at REAL, duration_ms INTEGER, state TEXT, bundle_path TEXT, title TEXT, body TEXT)", nil, nil, nil) == SQLITE_OK)
            }
            try #require(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
            do {
                let reader = try CapturesReader(context: context)
                #expect(reader.warnings.contains { $0.contains("Schema migration failed") })
                do {
                    let rows = try reader.list(limit: 10)
                    #expect(canRead && rows.isEmpty)
                } catch let error as CLIError {
                    #expect(!canRead && error.errorBody.code == "database_error")
                    #expect(error.errorBody.fix?.contains("Schema migration failed") == true)
                }
            } catch { sqlite3_exec(db, "ROLLBACK", nil, nil, nil); throw error }
            try #require(sqlite3_exec(db, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        }
    }
    private func runCLI(_ arguments: [String], support: URL? = nil, environment: [String: String] = [:]) throws -> (code: Int32, data: Data, stderr: Data) {
        let directory = Bundle(for: CapturesCLITestBundle.self).bundleURL.deletingLastPathComponent()
        let binary = directory.appendingPathComponent("muesli-cli")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path))
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = binary
        process.arguments = ["captures"] + arguments + (support.map { ["--support-dir", $0.path] } ?? [])
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "MUESLI_DB_PATH"); env.removeValue(forKey: "MUESLI_SUPPORT_DIR")
        process.environment = env.merging(environment) { _, new in new }
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data, stderr)
    }
    private func cli(_ arguments: [String], support: URL? = nil, environment: [String: String] = [:]) throws -> (code: Int32, json: [String: Any]) {
        let result = try runCLI(arguments, support: support, environment: environment)
        let data = result.data, stderr = result.stderr
        let object = try? JSONSerialization.jsonObject(with: data)
        let json = try #require(object as? [String: Any], Comment(rawValue:
            "CLI \(arguments) exited \(result.code): \(String(decoding: data, as: UTF8.self)) \(String(decoding: stderr, as: UTF8.self))"))
        let meta = try #require(json["meta"] as? [String: Any])
        #expect(meta["schemaVersion"] as? Int == 1)
        #expect(json["command"] as? String == "muesli-cli captures \(arguments[0])")
        if let support { #expect(meta["dbPath"] as? String == support.appendingPathComponent("muesli.db").path) }
        return (result.code, json)
    }
    private func error(_ result: (code: Int32, json: [String: Any]), code: String, exit: Int32) throws -> String {
        #expect(result.code == exit && result.json["ok"] as? Bool == false)
        let body = try #require(result.json["error"] as? [String: Any])
        #expect(body["code"] as? String == code)
        return try #require(body["message"] as? String)
    }
    private func warnings(_ json: [String: Any]) -> [String] { (json["meta"] as? [String: Any])?["warnings"] as? [String] ?? [] }
    @Test func discoversAndParsesAllFourCommands() throws {
        for arguments in [["captures", "list"], ["captures", "get", "latest", "--manifest"],
                          ["captures", "frames", "latest"], ["captures", "zoom", "latest", "--mark", "1"]] {
            _ = try MuesliCLI.parseAsRoot(arguments + ["--support-dir", "/tmp/scrawl-fixture"])
        }
        #expect(try CapturesListCommand.parse([]).limit == 10)
        #expect(CapturesZoomCommand.helpMessage().contains("Scrawl"))
        let help = try runCLI(["zoom", "--help"])
        #expect(help.code == 0 && String(decoding: help.data, as: UTF8.self).contains("Scrawl"))
    }
    @Test func absentDatabaseAndInvalidOptionsUseExistingEnvelopes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scrawl-absent-\(UUID())")
        let listed = try cli(["list"], support: root)
        #expect(listed.code == 0 && listed.json["ok"] as? Bool == true)
        #expect((listed.json["data"] as? [Any])?.isEmpty == true && !warnings(listed.json).isEmpty)
        for arguments in [["get", "latest"], ["frames", "latest"], ["zoom", "latest", "--at", "0:00"]] {
            _ = try error(cli(arguments, support: root), code: "database_unavailable", exit: 5)
        }
        for arguments in [["list", "--limit", "0"], ["list", "--limit", "bad"], ["list", "--unknown"],
                          ["zoom", "latest"], ["zoom", "latest", "--mark", "0"], ["zoom", "latest", "--mark", "-1"],
                          ["zoom", "latest", "--mark", "1", "--at", "0:00"]] {
            _ = try error(cli(arguments, support: root), code: "invalid_input", exit: 4)
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
    @Test func latestRetainsBusyCaptureAndStoreOrdering() throws {
        try withFeedbackStore { store, _, root in
            _ = try error(cli(["get", "latest"], support: root), code: "not_found", exit: 3)
            var old = try store.begin(target: feedbackTarget(), now: Date(timeIntervalSince1970: 1))
            old.state = .failed; old.durationMs = 500; try store.publish(old); store.release(id: old.id)
            let a = try store.begin(target: feedbackTarget(), now: Date(timeIntervalSince1970: 2))
            let b = try store.begin(target: feedbackTarget(), now: Date(timeIntervalSince1970: 2))
            defer { store.release(id: a.id); store.release(id: b.id) }
            let expected = [a.id, b.id].sorted(by: >)
            let listed = try cli(["list", "--limit", "2"], support: root)
            let rows = try #require(listed.json["data"] as? [[String: Any]])
            #expect(rows.compactMap { $0["id"] as? String } == expected)
            #expect(rows.allSatisfy { ($0["bundlePath"] as? String)?.hasPrefix(root.resolvingSymlinksInPath().path + "/feedback-captures/") == true })
            let got = try cli(["get", "latest"], support: root)
            let data = try #require(got.json["data"] as? [String: Any])
            #expect(data["id"] as? String == expected[0] && data["state"] as? String == "recording")
            #expect(data["capture"] == nil && (data["failures"] as? [Any])?.isEmpty == true)
            #expect(!warnings(got.json).isEmpty)
            let paths = try #require(data["paths"] as? [String: Any])
            #expect((paths["manifest"] as? String)?.hasSuffix("unfinished.json") == true)
            #expect((data["summary"] as? String)?.contains("unfinished.json") == true)
            _ = try error(cli(["zoom", "latest", "--mark", "1"], support: root), code: "invalid_input", exit: 4)
            _ = try error(cli(["get", "fc-1-ffff"], support: root), code: "not_found", exit: 3)
            #expect(!FileManager.default.fileExists(atPath: try store.mediaURL(id: expected[0], path: "capture.json").path))
        }
    }
    @Test func savedSummaryAndAvailableFramesKeepExactPayloads() throws {
        try withFeedbackStore { store, _, root in
            var m = try store.begin(target: feedbackTarget())
            m.state = .recovered; m.durationMs = 4000; m.video = "recording.mp4"; m.audio = "narration.wav"
            m.contactSheet = "contact-sheet.png"; m.failures = [.init(stage: "video", message: "fixture video missing")]
            m.keyframes = [1, 2].map { .init(index: $0, t: Int64($0 * 1000), reason: "click", file: "frames/\($0).png",
                eventIndex: 0, markId: "m1", said: "fixture", saidRange: .init(from: 0, to: 1)) }
            try FileManager.default.createDirectory(at: store.mediaURL(id: m.id, path: "frames"), withIntermediateDirectories: false)
            for path in ["frames/1.png", "contact-sheet.png", "narration.wav"] {
                try Data([1]).write(to: store.mediaURL(id: m.id, path: path))
            }
            try Data("Saved Scrawl summary".utf8).write(to: store.mediaURL(id: m.id, path: "summary.md"))
            try store.publish(m); store.release(id: m.id)
            let got = try cli(["get", m.id, "--manifest"], support: root)
            let data = try #require(got.json["data"] as? [String: Any]), paths = try #require(data["paths"] as? [String: Any])
            #expect(data["summary"] as? String == "Saved Scrawl summary")
            #expect(data["durationMs"] as? Int == 4000 && data["state"] as? String == "recovered")
            #expect((data["failures"] as? [[String: Any]])?.first?["stage"] as? String == "video")
            #expect(paths["video"] == nil && (paths["frames"] as? [String])?.count == 1)
            #expect((data["manifest"] as? [String: Any])?["video"] as? String == "recording.mp4")
            #expect(warnings(got.json).contains { $0.contains("frames/2.png") })
            let frames = try cli(["frames", m.id], support: root)
            let frameData = try #require(frames.json["data"] as? [String: Any])
            let frame = try #require((frameData["frames"] as? [[String: Any]])?.first)
            #expect(frame["index"] as? Int == 1 && frame["markId"] as? String == "m1")
            #expect(frame["saidRange"] != nil && frame["eventIndex"] as? Int == 0)
            #expect(frame["file"] as? String == (try store.mediaURL(id: m.id, path: "frames/1.png").path))
            #expect((frameData["contactSheet"] as? String)?.hasPrefix("/") == true)
            let noManifest = try cli(["get", m.id], support: root)
            #expect((noManifest.json["data"] as? [String: Any])?["manifest"] == nil)
            try FileManager.default.removeItem(at: store.mediaURL(id: m.id, path: "summary.md"))
            let fallback = try cli(["get", m.id], support: root)
            let text = try #require((fallback.json["data"] as? [String: Any])?["summary"] as? String)
            #expect(text.contains("captures zoom") && !text.contains("frames/2.png") && !text.contains("recording.mp4"))
        }
    }
    @Test func legacyAndVersionTwoManifestsAreValidatedBeforeDetailOutput() throws {
        try withFeedbackStore { store, _, root in
            var m = try store.begin(target: feedbackTarget()); m.state = .failed
            try store.publish(m); store.release(id: m.id)
            let path = try store.mediaURL(id: m.id, path: "capture.json")
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            for field in ["transcript", "events", "keyframes", "marks", "strokes", "failures"] { json.removeValue(forKey: field) }
            json["futureField"] = "tolerated"
            try JSONSerialization.data(withJSONObject: json).write(to: path, options: .atomic)
            let legacy = try cli(["get", "latest", "--manifest"], support: root)
            #expect(legacy.code == 0 && !warnings(legacy.json).isEmpty)
            #expect(warnings(legacy.json).contains { $0.contains("video") })
            #expect(((legacy.json["data"] as? [String: Any])?["failures"] as? [Any])?.isEmpty == true)
            json["version"] = 2
            try JSONSerialization.data(withJSONObject: json).write(to: path, options: .atomic)
            for arguments in [["get", "latest"], ["get", "latest", "--manifest"], ["frames", "latest"], ["zoom", "latest", "--at", "0:00"]] {
                let message = try error(cli(arguments, support: root), code: "invalid_input", exit: 4)
                #expect(message.contains("Unsupported Scrawl capture version 2"))
            }
        }
    }
    @Test func unsafeDeclarationsAndSymlinksAreRefusedOnReads() throws {
        try withFeedbackStore { store, _, root in
            var m = try store.begin(target: feedbackTarget()); m.state = .ready; m.video = "recording.mp4"
            try store.publish(m); store.release(id: m.id)
            let outside = root.appendingPathComponent("outside.mp4")
            try Data([1]).write(to: outside)
            let video = try store.mediaURL(id: m.id, path: "recording.mp4")
            try FileManager.default.createSymbolicLink(at: video, withDestinationURL: outside)
            _ = try error(cli(["get", m.id], support: root), code: "invalid_input", exit: 4)
            try FileManager.default.removeItem(at: video)
            let path = try store.mediaURL(id: m.id, path: "capture.json")
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            for unsafe in ["../outside.mp4", outside.path] {
                json["video"] = unsafe
                try JSONSerialization.data(withJSONObject: json).write(to: path, options: .atomic)
                _ = try error(cli(["frames", m.id], support: root), code: "invalid_input", exit: 4)
            }
            _ = try error(cli(["get", "../../escape"], support: root), code: "invalid_input", exit: 4)
        }
    }
    @Test func pathOptionsAndEnvironmentKeepExistingPrecedence() throws {
        try withFeedbackStore { _, _, root in
            let missing = root.appendingPathComponent("absent.db").path
            let env = ["MUESLI_DB_PATH": missing, "MUESLI_SUPPORT_DIR": root.appendingPathComponent("absent").path]
            let explicit = try cli(["list"], support: root, environment: env)
            #expect(explicit.code == 0 && warnings(explicit.json).isEmpty)
            let db = root.appendingPathComponent("muesli.db").path
            let fromDB = try cli(["list", "--db-path", db], environment: env)
            #expect(warnings(fromDB.json).isEmpty)
            #expect((fromDB.json["meta"] as? [String: Any])?["dbPath"] as? String == db)
            let fromEnvironment = try cli(["list"], environment: ["MUESLI_SUPPORT_DIR": root.path])
            #expect(warnings(fromEnvironment.json).isEmpty)
            #expect((fromEnvironment.json["meta"] as? [String: Any])?["dbPath"] as? String == db)
            let absent = try cli(["list"], environment: env)
            #expect(!warnings(absent.json).isEmpty)
            #expect((absent.json["meta"] as? [String: Any])?["dbPath"] as? String == missing)
        }
    }
    @Test func zoomDoesNotRecreateBundleDeletedAfterRendering() async throws {
        try await withFeedbackStoreAsync { store, root in
            var m = try store.begin(target: feedbackTarget()); m.state = .ready
            m.durationMs = 3250; m.videoOffsetMs = 250; m.video = "recording.mp4"
            try await FeedbackCaptureRendererTests().makeVideo(store.mediaURL(id: m.id, path: "recording.mp4"))
            m.strokes = [feedbackStroke(800, pin: 7)]; m.marks = FeedbackCaptureInk.marks(m.strokes)
            try store.publish(m); store.release(id: m.id)

            let bundle = try store.bundleURL(id: m.id)
            let deletingStore = try FeedbackCaptureStore(databaseURL: root.appendingPathComponent("muesli.db"), support: root)
            let reader = try CapturesReader(context: CLIContext(dbPath: nil, supportDir: root.path), renderZoom: { manifest, url, at, mark in
                let output = try await FeedbackCaptureRenderer.zoom(manifest, url: url, at: at, mark: mark)
                try deletingStore.delete(id: manifest.id)
                return output
            })

            do {
                _ = try await reader.zoom("latest", at: nil, mark: 1)
                Issue.record("Zoom returned artifacts after the capture was deleted")
            } catch let error as CLIError {
                #expect(error.errorBody.code == "not_found")
            }
            #expect(!FileManager.default.fileExists(atPath: bundle.path))
            #expect(try store.get(id: m.id) == nil)
        }
    }

    @Test func nativeZoomWritesOnlyPrivateZoomArtifactsAndKeepsActualCaptureTimes() async throws {
        try await withFeedbackStoreAsync { store, root in
            var m = try store.begin(target: feedbackTarget()); m.state = .ready
            m.durationMs = 3250; m.videoOffsetMs = 250; m.video = "recording.mp4"
            try await FeedbackCaptureRendererTests().makeVideo(store.mediaURL(id: m.id, path: "recording.mp4"))
            m.strokes = [feedbackStroke(800, pin: 7)]; m.marks = FeedbackCaptureInk.marks(m.strokes)
            m.transcript = .init(source: "fixture", text: "Look here", words: [
                .init(t0: 500, t1: 900, text: "Look"), .init(t0: 900, t1: 1200, text: "here")], segments: [], estimated: true)
            try store.publish(m); store.release(id: m.id)
            let manifestURL = try store.mediaURL(id: m.id, path: "capture.json"), original = try Data(contentsOf: manifestURL)
            let reader = try CapturesReader(context: CLIContext(dbPath: nil, supportDir: root.path))
            let (zoom, _) = try await reader.zoom("latest", at: nil, mark: 1)
            #expect(zoom.t0 == 0 && zoom.t1 == 1900 && zoom.said == "Look here" && zoom.estimated)
            #expect(zoom.words == m.transcript?.words && !zoom.frames.isEmpty && zoom.frames.count <= 6)
            let prefix = try store.bundleURL(id: m.id).path + "/zoom/"
            for frame in zoom.frames {
                #expect(frame.file.hasPrefix(prefix) && frame.t >= 250 && (frame.t - 250).isMultiple(of: 250))
            }
            let sheet = try #require(NSBitmapImageRep(data: Data(contentsOf: URL(fileURLWithPath: zoom.contactSheet))))
            #expect(max(sheet.pixelsWide, sheet.pixelsHigh) <= 1600)
            let directory = URL(fileURLWithPath: zoom.contactSheet).deletingLastPathComponent()
            #expect((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            #expect(try Data(contentsOf: manifestURL) == original)
            #expect(try store.list().first?.state == .ready)
            #expect(!FileManager.default.fileExists(atPath: try store.mediaURL(id: m.id, path: "frames").path))
            let second = try cli(["zoom", "latest", "--at", "0:01"], support: root)
            #expect(second.code == 0)
            #expect((second.json["data"] as? [String: Any])?["contactSheet"] as? String != zoom.contactSheet)
            _ = try error(cli(["zoom", "latest", "--mark", "7"], support: root), code: "invalid_input", exit: 4)
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await reader.zoom("latest", at: "0:01", mark: nil)
            }
            do { _ = try await cancelled.value; Issue.record("Cancelled Scrawl zoom returned artifacts") }
            catch let error as CLIError {
                guard case .invalidInput(let message, let fix) = error else { throw error }
                #expect(error.errorBody.code == "invalid_input" && message == "Scrawl zoom was cancelled." && fix == nil)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.deletingLastPathComponent().path).count == 2)
            let zoomRoot = directory.deletingLastPathComponent()
            let retained = try store.mediaURL(id: m.id, path: "retained-zoom")
            try FileManager.default.moveItem(at: zoomRoot, to: retained)
            try FileManager.default.createSymbolicLink(at: zoomRoot, withDestinationURL: retained)
            _ = try error(cli(["zoom", "latest", "--at", "0:01"], support: root), code: "invalid_input", exit: 4)
            #expect(try FileManager.default.contentsOfDirectory(atPath: retained.path).count == 2)
            try FileManager.default.removeItem(at: zoomRoot)
            try Data().write(to: store.mediaURL(id: m.id, path: "recording.mp4"))
            _ = try error(cli(["zoom", "latest", "--at", "0:01"], support: root), code: "invalid_input", exit: 4)
            #expect(!FileManager.default.fileExists(atPath: zoomRoot.path))
        }
    }
}
