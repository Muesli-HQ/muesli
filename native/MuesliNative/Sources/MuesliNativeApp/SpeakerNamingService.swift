import Foundation
import MuesliCore

/// Pure, recoverable profile-centroid refinement.
///
/// We never apply a blind in-place EMA. Instead each confirmed sample is appended
/// to the profile's retained `rawEmbeddings` (bounded), and the representative
/// embedding is recomputed from that set — so a bad sample can be recovered from
/// and a single borderline confirmation can't drag the centroid uncontrolled.
enum SpeakerProfileRefiner {
    static let maxRawEmbeddings = 20

    struct Refinement: Equatable {
        let embedding: [Float]
        let rawEmbeddings: [[Float]]
        let observationCount: Int
    }

    static func refine(
        existingRaw: [[Float]],
        adding embedding: [Float],
        cap: Int = maxRawEmbeddings
    ) -> Refinement {
        var raw = existingRaw
        raw.append(embedding)
        if cap > 0, raw.count > cap {
            raw.removeFirst(raw.count - cap)
        }
        let representative = SpeakerClusterAggregator.representativeEmbedding(from: raw) ?? embedding
        return Refinement(embedding: representative, rawEmbeddings: raw, observationCount: raw.count)
    }
}

/// Applies naming/confirmation decisions to the store: updates the per-meeting
/// row and creates/refines the linked voice profile. Operates directly on
/// `DictationStore` so it is testable without the full controller.
struct SpeakerNamingService {
    let store: DictationStore
    var maxRawEmbeddings: Int = SpeakerProfileRefiner.maxRawEmbeddings
    private let dimension = SpeakerClusterAggregator.embeddingDimension

    /// Generates new profile IDs. Injectable for deterministic tests.
    var makeID: () -> String = { UUID().uuidString }

    /// Manually name (or correct) a speaker. A correction to a *different* name
    /// never touches the previously-linked profile (R6): we resolve a target
    /// profile by the new name (or create one), leaving the mismatched profile
    /// untouched.
    func rename(meetingID: Int64, label: String, to newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let rows = try store.meetingSpeakers(for: meetingID)
        let existing = rows.first { $0.speakerLabel == label }
        let embedding = existing?.embedding ?? []

        var profileID: String? = nil
        if embedding.count == dimension {
            profileID = try resolveProfile(preferredID: nil, name: trimmed, embedding: embedding)
        }

        if let existing {
            try store.updateMeetingSpeaker(
                id: existing.id,
                profileID: profileID,
                displayName: trimmed,
                matchDistance: nil,
                matchState: .confirmed
            )
        } else {
            // Older meeting with no captured voiceprint: still allow the rename as
            // a display-only overlay (no profile, so no cross-call recognition).
            try store.insertMeetingSpeaker(
                meetingID: meetingID,
                speakerLabel: label,
                embedding: embedding,
                profileID: profileID,
                displayName: trimmed,
                matchDistance: nil,
                matchState: .confirmed
            )
        }
    }

    /// Confirm a borderline suggestion: refine the *specific* suggested profile
    /// and mark the row confirmed.
    func confirm(meetingID: Int64, label: String) throws {
        let rows = try store.meetingSpeakers(for: meetingID)
        guard let row = rows.first(where: { $0.speakerLabel == label }),
              let name = row.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return }

        var profileID = row.profileID
        if row.embedding.count == dimension {
            profileID = try resolveProfile(preferredID: row.profileID, name: name, embedding: row.embedding)
        }
        try store.updateMeetingSpeaker(
            id: row.id,
            profileID: profileID,
            displayName: name,
            matchDistance: row.matchDistance,
            matchState: .confirmed
        )
    }

    /// Reject a suggestion: drop back to an unnamed `Speaker N`. Profiles untouched.
    func reject(meetingID: Int64, label: String) throws {
        let rows = try store.meetingSpeakers(for: meetingID)
        guard let row = rows.first(where: { $0.speakerLabel == label }) else { return }
        try store.updateMeetingSpeaker(
            id: row.id,
            profileID: nil,
            displayName: nil,
            matchDistance: nil,
            matchState: .unmatched
        )
    }

    /// Find the profile to attach to and refine it, or create a new one.
    /// `preferredID` (confirm path) refines that exact profile; otherwise we
    /// match by name so renames don't pollute a mismatched profile.
    private func resolveProfile(preferredID: String?, name: String, embedding: [Float]) throws -> String {
        let profiles = try store.speakerProfiles()
        let target = preferredID.flatMap { id in profiles.first { $0.id == id } }
            ?? profiles.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }

        if let target {
            let refinement = SpeakerProfileRefiner.refine(
                existingRaw: target.rawEmbeddings,
                adding: embedding,
                cap: maxRawEmbeddings
            )
            try store.upsertSpeakerProfile(
                id: target.id,
                name: name,
                embedding: refinement.embedding,
                rawEmbeddings: refinement.rawEmbeddings,
                observationCount: refinement.observationCount
            )
            return target.id
        }

        let newID = makeID()
        let refinement = SpeakerProfileRefiner.refine(existingRaw: [], adding: embedding, cap: maxRawEmbeddings)
        try store.upsertSpeakerProfile(
            id: newID,
            name: name,
            embedding: refinement.embedding,
            rawEmbeddings: refinement.rawEmbeddings,
            observationCount: refinement.observationCount
        )
        return newID
    }
}
