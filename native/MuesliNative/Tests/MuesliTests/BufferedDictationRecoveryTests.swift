import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Buffered dictation recovery")
struct BufferedDictationRecoveryTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func permissions(_ url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return try #require(value).intValue & 0o777
    }

    @Test("fallback sidecars preserve exact text privately without overwriting audio or prior text")
    func transcriptSidecars() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("recording.wav")
        let audio = Data([8, 7, 6])
        try audio.write(to: source)
        let transcript = " Draft e\u{301}\nதமிழ் 👩🏽‍💻 "
        let first = try BufferedDictationRecovery.saveTranscript(transcript, beside: source)
        let second = try BufferedDictationRecovery.saveTranscript("", beside: source)
        #expect(first == source.appendingPathExtension("transcript.txt"))
        #expect(first != second)
        #expect(second.deletingLastPathComponent().path == root.path)
        #expect(second.lastPathComponent.hasSuffix(".transcript.txt"))
        #expect(try Data(contentsOf: first) == Data(transcript.utf8))
        #expect(try Data(contentsOf: second).isEmpty)
        #expect(try permissions(first) == 0o600)
        #expect(try permissions(second) == 0o600)
        #expect(try Data(contentsOf: source) == audio)
    }

    @Test("fallback does not follow an existing sidecar symlink")
    func sidecarSymlinkIsNotOverwritten() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("recording.wav")
        let audio = Data([1, 3, 5])
        try audio.write(to: source)
        let occupied = source.appendingPathExtension("transcript.txt")
        try FileManager.default.createSymbolicLink(at: occupied, withDestinationURL: source)
        let saved = try BufferedDictationRecovery.saveTranscript("recover me", beside: source)
        #expect(saved != occupied)
        #expect(try Data(contentsOf: source) == audio)
        #expect(try Data(contentsOf: saved) == Data("recover me".utf8))
    }

    @Test("fallback errors propagate when the audio directory is unavailable")
    func sidecarFailurePropagates() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let unavailable = root.appendingPathComponent("missing/recording.wav")
        #expect(throws: (any Error).self) {
            try BufferedDictationRecovery.saveTranscript("draft", beside: unavailable)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("recovery preserves exact audio and Unicode transcript in private unique folders")
    func savesIndependentCopies() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("recording.wav")
        let audio = Data([82, 73, 70, 70, 0, 255, 128, 10])
        try audio.write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.path)
        let destination = root.appendingPathComponent("Dictation Recovery")
        let transcript = "  Hello e\u{301} 👩🏽‍💻\nதமிழ்\tworld  "
        let first = try BufferedDictationRecovery.save(wavURL: source, transcript: transcript, directory: destination)
        let second = try BufferedDictationRecovery.save(wavURL: source, transcript: "", directory: destination)
        #expect(first != second)
        #expect(first.deletingLastPathComponent().path == destination.path)
        for session in [first, second] {
            #expect(try Data(contentsOf: session.appendingPathComponent("audio.wav")) == audio)
            #expect(try permissions(session) == 0o700)
            #expect(try permissions(session.appendingPathComponent("audio.wav")) == 0o600)
            #expect(try permissions(session.appendingPathComponent("transcript.txt")) == 0o600)
        }
        #expect(try Data(contentsOf: first.appendingPathComponent("transcript.txt")) == Data(transcript.utf8))
        #expect(try Data(contentsOf: second.appendingPathComponent("transcript.txt")).isEmpty)
        #expect(try Data(contentsOf: source) == audio)
        #expect(try permissions(source) == 0o640)
    }

    @Test("unwritable destination errors propagate without changing source or prior content")
    func invalidDestination() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        let audio = Data([1, 2, 3])
        try audio.write(to: source)
        let destination = root.appendingPathComponent("occupied")
        let existing = Data("keep me".utf8)
        try existing.write(to: destination)
        #expect(throws: (any Error).self) {
            try BufferedDictationRecovery.save(wavURL: source, transcript: "draft", directory: destination)
        }
        #expect(try Data(contentsOf: source) == audio)
        #expect(try Data(contentsOf: destination) == existing)
    }

    @Test("missing or symbolic-link input fails before creating recovery content")
    func invalidInput() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.wav")
        let audio = Data([4, 5, 6])
        try audio.write(to: source)
        let link = root.appendingPathComponent("link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let destination = root.appendingPathComponent("recovery")
        for input in [root.appendingPathComponent("missing.wav"), link, root] {
            #expect(throws: (any Error).self) {
                try BufferedDictationRecovery.save(wavURL: input, transcript: "draft", directory: destination)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try Data(contentsOf: source) == audio)
    }
}
