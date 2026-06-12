import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("Speaker naming service", .serialized)
struct SpeakerNamingControllerLogicTests {
    private let dim = SpeakerClusterAggregator.embeddingDimension

    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-naming-test-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    private func vec(_ value: Float) -> [Float] {
        (0..<dim).map { Float($0) * 0.001 + value }
    }

    /// A 256-D unit basis vector (1 at `axis`, 0 elsewhere) — distinct axes are
    /// cosine-orthogonal (distance 1.0), the same axis is distance 0.
    private func basis(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        v[axis] = 1
        return v
    }

    private func service(_ store: DictationStore, ids: [String] = []) -> SpeakerNamingService {
        var svc = SpeakerNamingService(store: store)
        if !ids.isEmpty {
            var queue = ids
            svc.makeID = { queue.isEmpty ? UUID().uuidString : queue.removeFirst() }
        }
        return svc
    }

    private func makeMeetingWithSpeaker(
        _ store: DictationStore,
        label: String = "Speaker 1",
        embedding: [Float],
        profileID: String? = nil,
        displayName: String? = nil,
        state: SpeakerMatchState = .unmatched
    ) throws -> (meetingID: Int64, rowID: Int64) {
        let meetingID = try store.createLiveMeeting(title: "M", calendarEventID: nil, startTime: Date())
        let rowID = try store.insertMeetingSpeaker(
            meetingID: meetingID, speakerLabel: label, embedding: embedding,
            profileID: profileID, displayName: displayName, matchDistance: nil, matchState: state
        )
        return (meetingID, rowID)
    }

    // MARK: - SpeakerProfileRefiner (pure)

    @Test("refine appends a sample and re-averages recoverably")
    func refineAppends() {
        let r = SpeakerProfileRefiner.refine(existingRaw: [vec(0.1)], adding: vec(0.5))
        #expect(r.rawEmbeddings.count == 2)        // raw retained → recoverable
        #expect(r.observationCount == 2)
        #expect(r.embedding.count == 256)
        let mag = r.embedding.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        #expect(abs(mag - 1.0) < 1e-4)             // unit-length
    }

    @Test("refine caps retained raw embeddings, dropping oldest")
    func refineCaps() {
        let existing = (0..<20).map { vec(Float($0) * 0.01) }
        let r = SpeakerProfileRefiner.refine(existingRaw: existing, adding: vec(9.0), cap: 20)
        #expect(r.rawEmbeddings.count == 20)       // capped
        #expect(r.rawEmbeddings.last == vec(9.0))  // newest kept
        #expect(r.rawEmbeddings.first == vec(0.01)) // oldest (index 0) dropped
    }

    // MARK: - rename

    @Test("renaming an unmatched speaker creates and links a profile")
    func renameCreatesProfile() throws {
        let store = try makeStore()
        let emb = vec(0.2)
        let (meetingID, _) = try makeMeetingWithSpeaker(store, embedding: emb)

        try service(store, ids: ["bob-id"]).rename(meetingID: meetingID, label: "Speaker 1", to: "Bob")

        let row = try #require(try store.meetingSpeakers(for: meetingID).first)
        #expect(row.matchState == .confirmed)
        #expect(row.displayName == "Bob")
        #expect(row.profileID == "bob-id")
        let profile = try #require(try store.speakerProfile(id: "bob-id"))
        #expect(profile.name == "Bob")
        #expect(profile.observationCount == 1)
    }

    @Test("renaming to an existing profile name links and refines it")
    func renameRefinesExisting() throws {
        let store = try makeStore()
        try store.upsertSpeakerProfile(id: "bob-id", name: "Bob", embedding: vec(0.2), rawEmbeddings: [vec(0.2)], observationCount: 1)
        let (meetingID, _) = try makeMeetingWithSpeaker(store, embedding: vec(0.25))

        try service(store).rename(meetingID: meetingID, label: "Speaker 1", to: "Bob")

        let profiles = try store.speakerProfiles()
        #expect(profiles.count == 1)               // no duplicate Bob
        #expect(profiles.first?.observationCount == 2) // refined
        #expect(try store.meetingSpeakers(for: meetingID).first?.profileID == "bob-id")
    }

    // Covers R6.
    @Test("correcting a wrong auto-match does not pollute the mismatched profile")
    func correctionLeavesMismatchedProfileUntouched() throws {
        let store = try makeStore()
        // Auto-matched to Bob, but it's really Carol.
        try store.upsertSpeakerProfile(id: "bob-id", name: "Bob", embedding: vec(0.2), rawEmbeddings: [vec(0.2)], observationCount: 1)
        let carolEmb = vec(0.9)
        let (meetingID, _) = try makeMeetingWithSpeaker(
            store, embedding: carolEmb, profileID: "bob-id", displayName: "Bob", state: .auto
        )

        try service(store, ids: ["carol-id"]).rename(meetingID: meetingID, label: "Speaker 1", to: "Carol")

        // Bob untouched.
        let bob = try #require(try store.speakerProfile(id: "bob-id"))
        #expect(bob.observationCount == 1)
        #expect(bob.rawEmbeddings.count == 1)
        // Carol created and linked.
        let row = try #require(try store.meetingSpeakers(for: meetingID).first)
        #expect(row.profileID == "carol-id")
        #expect(row.displayName == "Carol")
        #expect(try store.speakerProfile(id: "carol-id")?.name == "Carol")
    }

    @Test("renaming a speaker with no voiceprint is display-only (no profile)")
    func renameWithoutEmbedding() throws {
        let store = try makeStore()
        let (meetingID, _) = try makeMeetingWithSpeaker(store, embedding: []) // older meeting

        try service(store).rename(meetingID: meetingID, label: "Speaker 1", to: "Bob")

        let row = try #require(try store.meetingSpeakers(for: meetingID).first)
        #expect(row.displayName == "Bob")
        #expect(row.matchState == .confirmed)
        #expect(row.profileID == nil)
        #expect(try store.speakerProfiles().isEmpty)
    }

    @Test("blank rename is a no-op")
    func renameBlankNoOp() throws {
        let store = try makeStore()
        let (meetingID, _) = try makeMeetingWithSpeaker(store, embedding: vec(0.2))
        try service(store).rename(meetingID: meetingID, label: "Speaker 1", to: "   ")
        let row = try #require(try store.meetingSpeakers(for: meetingID).first)
        #expect(row.matchState == .unmatched)
        #expect(row.displayName == nil)
    }

    // MARK: - confirm / reject

    @Test("confirming a suggestion links the suggested profile and refines it")
    func confirmSuggestion() throws {
        let store = try makeStore()
        try store.upsertSpeakerProfile(id: "bob-id", name: "Bob", embedding: vec(0.2), rawEmbeddings: [vec(0.2)], observationCount: 1)
        let (meetingID, _) = try makeMeetingWithSpeaker(
            store, embedding: vec(0.22), profileID: "bob-id", displayName: "Bob", state: .suggested
        )

        try service(store).confirm(meetingID: meetingID, label: "Speaker 1")

        let row = try #require(try store.meetingSpeakers(for: meetingID).first)
        #expect(row.matchState == .confirmed)
        #expect(row.profileID == "bob-id")
        #expect(try store.speakerProfile(id: "bob-id")?.observationCount == 2)
    }

    @Test("same name + close voice refines one profile")
    func sameNameCloseVoiceRefines() throws {
        let store = try makeStore()
        let m1 = try makeMeetingWithSpeaker(store, label: "Speaker 1", embedding: basis(0))
        let m2 = try makeMeetingWithSpeaker(store, label: "Speaker 1", embedding: basis(0))

        try service(store, ids: ["bob-1", "bob-2"]).rename(meetingID: m1.meetingID, label: "Speaker 1", to: "Bob")
        try service(store, ids: ["bob-2"]).rename(meetingID: m2.meetingID, label: "Speaker 1", to: "Bob")

        let profiles = try store.speakerProfiles()
        #expect(profiles.count == 1)                 // same voice → one Bob
        #expect(profiles.first?.observationCount == 2)
    }

    @Test("same name + far voice creates a separate profile (no centroid poisoning)")
    func sameNameFarVoiceSplits() throws {
        let store = try makeStore()
        let m1 = try makeMeetingWithSpeaker(store, label: "Speaker 1", embedding: basis(0))
        let m2 = try makeMeetingWithSpeaker(store, label: "Speaker 1", embedding: basis(1)) // orthogonal → distance 1.0

        try service(store, ids: ["bob-1"]).rename(meetingID: m1.meetingID, label: "Speaker 1", to: "Bob")
        try service(store, ids: ["bob-2"]).rename(meetingID: m2.meetingID, label: "Speaker 1", to: "Bob")

        let profiles = try store.speakerProfiles()
        #expect(profiles.count == 2)                 // two different people sharing a name
        #expect(profiles.allSatisfy { $0.name == "Bob" })
        #expect(profiles.allSatisfy { $0.observationCount == 1 })
    }

    @Test("confirming a row with no candidate name is a no-op")
    func confirmNoNameNoOp() throws {
        let store = try makeStore()
        let (meetingID, _) = try makeMeetingWithSpeaker(store, embedding: vec(0.2), state: .unmatched)
        try service(store).confirm(meetingID: meetingID, label: "Speaker 1")
        let row = try #require(try store.meetingSpeakers(for: meetingID).first)
        #expect(row.matchState == .unmatched)
        #expect(try store.speakerProfiles().isEmpty)
    }

    @Test("refiner with cap=0 keeps all raw embeddings unbounded")
    func refinerUnbounded() {
        let existing = (0..<30).map { vec(Float($0) * 0.01) }
        let r = SpeakerProfileRefiner.refine(existingRaw: existing, adding: vec(9.0), cap: 0)
        #expect(r.rawEmbeddings.count == 31) // no trimming
    }

    @Test("rejecting a suggestion returns to unmatched without touching profiles")
    func rejectSuggestion() throws {
        let store = try makeStore()
        try store.upsertSpeakerProfile(id: "bob-id", name: "Bob", embedding: vec(0.2), rawEmbeddings: [vec(0.2)], observationCount: 1)
        let (meetingID, _) = try makeMeetingWithSpeaker(
            store, embedding: vec(0.22), profileID: "bob-id", displayName: "Bob", state: .suggested
        )

        try service(store).reject(meetingID: meetingID, label: "Speaker 1")

        let row = try #require(try store.meetingSpeakers(for: meetingID).first)
        #expect(row.matchState == .unmatched)
        #expect(row.profileID == nil)
        #expect(row.displayName == nil)
        #expect(try store.speakerProfile(id: "bob-id")?.observationCount == 1) // untouched
    }
}
