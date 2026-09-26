import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Voice profile storage", .serialized)
struct VoiceProfileStoreTests {
    private func fixture() throws -> (URL, VoiceProfileStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (root, try VoiceProfileStore(supportDirectory: root))
    }

    private func profile() throws -> OwnerVoiceProfile {
        var reference = [Float](repeating: 0, count: 256)
        reference[0] = 1
        return try OwnerVoiceProfile(modelIdentity: "fixture-model-sha256", references: [reference, reference], acceptedSpeechSeconds: 20)
    }

    @Test("round trip uses restricted local storage and does not export audio")
    func roundTripAndPermissions() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.replace(profile())
        #expect(try store.load(modelIdentity: "fixture-model-sha256")?.references.count == 2)
        #expect(try store.load(modelIdentity: "different-model") == nil)
        let fileMode = try FileManager.default.attributesOfItem(atPath: store.profileURL.path)[.posixPermissions] as? NSNumber
        let directoryMode = try FileManager.default.attributesOfItem(atPath: store.profileURL.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        #expect(fileMode?.intValue == 0o600)
        #expect(directoryMode?.intValue == 0o700)
        try store.delete()
        #expect(try store.load(modelIdentity: "fixture-model-sha256") == nil)
    }

    @Test("reject invalid vectors and preserve prior profile on failed replacement")
    func invalidReplacement() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.replace(profile())
        for vector in [[Float](repeating: 0, count: 256), [Float](repeating: 1, count: 255), [Float](repeating: .nan, count: 256)] {
            #expect(throws: OwnerVoiceProfileError.self) {
                try store.replace(OwnerVoiceProfile(modelIdentity: "fixture-model-sha256", references: [vector, vector], acceptedSpeechSeconds: 20))
            }
        }
        #expect(try store.load(modelIdentity: "fixture-model-sha256")?.references.count == 2)
    }

    @Test("corrupt and unknown schema profiles are unavailable")
    func corruptProfile() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.replace(profile())
        try Data("not json".utf8).write(to: store.profileURL)
        #expect(try store.load(modelIdentity: "fixture-model-sha256") == nil)
        try store.replace(profile())
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.profileURL)) as? [String: Any])
        object["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: object).write(to: store.profileURL)
        #expect(try store.load(modelIdentity: "fixture-model-sha256") == nil)
    }

    @Test("profiles written before stable identity migrate once and keep their identity")
    func migratesProfileWithoutIdentity() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try profile()
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "id")
        try JSONSerialization.data(withJSONObject: object).write(to: store.profileURL)

        let migrated = try #require(store.loadStored())
        let loadedAgain = try #require(store.loadStored())
        let savedObject = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.profileURL)) as? [String: Any])

        #expect(migrated.id == loadedAgain.id)
        #expect(savedObject["id"] as? String == migrated.id.uuidString)
        #expect(migrated.modelIdentity == original.modelIdentity)
        #expect(migrated.references == original.references)
        #expect(migrated.acceptedSpeechSeconds == original.acceptedSpeechSeconds)
    }

    @Test("startup cleans only app-owned stale enrollment artifacts")
    func staleEnrollmentCleanup() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let unrelated = root.appendingPathComponent("unrelated.wav")
        try Data([1]).write(to: unrelated)
        let temporary = store.enrollmentDirectory.appendingPathComponent("interrupted.wav")
        try Data([1]).write(to: temporary)
        _ = try VoiceProfileStore(supportDirectory: root)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test("delete or replacement invalidates in-flight publication")
    func deletedGenerationCannotPublish() {
        var generation = OwnerVoiceGeneration()
        let token = generation.begin()
        generation.invalidate()
        #expect(!generation.accepts(token))
        let replacement = generation.begin()
        #expect(generation.accepts(replacement))
        #expect(!generation.accepts(token))
    }
    @Test("failed filesystem publication preserves the previous profile")
    func failedAtomicPublication() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try profile()
        try store.replace(original)
        let directory = store.profileURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        #expect(throws: (any Error).self) { try store.replace(profile()) }
        #expect(try store.load(modelIdentity: original.modelIdentity) == original)
    }

}
