import Foundation
import MuesliCore
import Observation

struct MeetingSpeakerSearchInput: Equatable, Sendable {
    let query: String
    let version: MeetingTranscriptVersion?
    let speakerRevision: Int64?
}

enum MeetingSpeakerEditorError: LocalizedError {
    case busy, invalidAction, conflict
    var errorDescription: String? {
        switch self {
        case .busy: return "Speaker editing is unavailable while audio capture or meeting processing is active."
        case .invalidAction: return "That correction is unavailable. Select a speaker and complete words from one block."
        case .conflict: return "The transcript or speakers changed. Reload the editor before making another correction."
        }
    }
}

@MainActor @Observable
final class MeetingSpeakerEditorModel {
    var snapshot: MeetingSpeakerSnapshot?
    var samples: [MeetingSpeakerKey: MeetingSpeakerSampleRange] = [:]
    var matchingTurns: [MeetingSpeakerTurn] = []
    var isBusy = false
    var error: String?
    private var generation = UUID()
    private var searchGeneration = UUID()

    func load(id: Int64, controller: MuesliController) async {
        let token = UUID(); generation = token; isBusy = true
        let loaded = await controller.loadMeetingSpeakerPresentation(id: id)
        let ranges = await sampleRanges(loaded.snapshot)
        guard generation == token, !Task.isCancelled else { return }
        snapshot = loaded.snapshot; samples = ranges; isBusy = false; error = nil
    }

    @discardableResult
    func apply(_ action: MeetingSpeakerCorrection, id: Int64, controller: MuesliController) async -> Bool {
        guard !isBusy, let expected = snapshot else { return false }
        let token = UUID(); generation = token; isBusy = true; error = nil
        do {
            let saved = try await controller.applyMeetingSpeakerCorrection(id: id, action: action, expected: expected)
            let ranges = await sampleRanges(saved)
            guard generation == token, !Task.isCancelled else { return false }
            snapshot = saved; samples = ranges
        } catch {
            guard generation == token else { return false }
            self.error = error.localizedDescription
            isBusy = false
            return false
        }
        isBusy = false
        return true
    }

    static func assignableSpeakers(_ speakers: [MeetingSpeaker], for turn: MeetingSpeakerTurn) -> [MeetingSpeaker] {
        speakers.filter { $0.key != turn.speaker }
    }

    func updateMatchingTurns(_ input: MeetingSpeakerSearchInput) async {
        let token = UUID()
        searchGeneration = token
        matchingTurns = []
        guard let snapshot else {
            return
        }
        guard snapshot.version == input.version, snapshot.state.revision == input.speakerRevision else { return }
        let state = snapshot.state
        let matches = await Task.detached(priority: .userInitiated) {
            state.matchingTurns(query: input.query)
        }.value
        guard searchGeneration == token, !Task.isCancelled,
              self.snapshot?.version == input.version,
              self.snapshot?.state.revision == input.speakerRevision else { return }
        matchingTurns = matches
    }

    private func sampleRanges(_ snapshot: MeetingSpeakerSnapshot?) async -> [MeetingSpeakerKey: MeetingSpeakerSampleRange] {
        await Task.detached(priority: .utility) { () -> [MeetingSpeakerKey: MeetingSpeakerSampleRange] in
            guard let state = snapshot?.state else { return [:] }
            return Dictionary(uniqueKeysWithValues: state.activeSpeakers.compactMap { speaker in
                state.sampleRange(for: speaker.key).map { (speaker.key, $0) }
            })
        }.value
    }

    func cancelPendingPresentation() { generation = UUID(); isBusy = false }
}
