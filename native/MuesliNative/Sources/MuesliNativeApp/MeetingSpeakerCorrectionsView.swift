import Foundation
import MuesliCore
import SwiftUI

extension Notification.Name {
    static let meetingSpeakerIdentityDidChange = Notification.Name("meetingSpeakerIdentityDidChange")
}

enum MeetingSpeakerCorrectionError: LocalizedError {
    case editedTranscript, removedParticipant
    var errorDescription: String? {
        switch self {
        case .editedTranscript: "Speaker mapping is unavailable for edited text. Re-transcribe a saved recording to rebuild it."
        case .removedParticipant: "That participant is no longer in this meeting. Choose another participant."
        }
    }
}

/// Consumes the existing roster; Contacts creation and selection remain in the roster UI.
struct MeetingSpeakerCorrectionsView: View {
    let meeting: MeetingRecord
    let controller: MuesliController
    let state: MeetingSpeakerState?
    @State private var participants: [MeetingParticipant] = []
    @State private var roles: [String: MeetingParticipantRole] = [:]
    @State private var error: String?

    var body: some View {
        DisclosureGroup("Speaker labels") {
            if let state, state.matches(meeting.rawTranscript) {
                ForEach(state.candidates, id: \.key) { candidate in
                    let assignment = state.assignments[candidate.key]
                    HStack {
                        Text(assignment?.label ?? "Unknown speaker")
                        Text(candidate.key.source.rawValue.capitalized).foregroundStyle(.secondary)
                        Spacer()
                        Menu("Assign speaker") {
                            Button("Automatic") { change(candidate.key, automatic: true) }
                            Button("This is me") { change(candidate.key, isOwner: true) }
                            ForEach(participants) { person in
                                Button(person.displayName) { change(candidate.key, participantID: person.participantIdentifier) }
                            }
                            if assignment?.needsParticipantReview == true {
                                Button("Keep this name") { change(candidate.key, retainName: true) }
                            }
                        }
                    }
                    if assignment?.needsParticipantReview == true {
                        Text("This participant was removed. Choose a participant, keep this name, or return to automatic labels.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(participants) { person in
                    HStack {
                        Text(person.displayName)
                        Spacer()
                        Picker("Role", selection: Binding(
                            get: { roles[person.participantIdentifier] ?? .unknown },
                            set: { role in
                                do {
                                    try controller.setMeetingIdentityRole(meetingID: meeting.id, participantID: person.participantIdentifier, role: role)
                                    roles[person.participantIdentifier] = role
                                } catch { self.error = error.localizedDescription }
                            }
                        )) {
                            Text("Unknown").tag(MeetingParticipantRole.unknown)
                            Text("This is me").tag(MeetingParticipantRole.owner)
                            Text("Other participant").tag(MeetingParticipantRole.remote)
                        }.frame(maxWidth: 210)
                    }
                }
                if state.summaryIsStale {
                    Text("Speaker labels changed. Use Re-summarize to update the notes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Speaker mapping is unavailable for this transcript. Re-transcribe a saved recording to rebuild it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task(id: meeting.id) { await loadRoster() }
        .onReceive(NotificationCenter.default.publisher(for: .meetingParticipantsDidChange)) { notification in
            if notification.object as? Int64 == meeting.id { Task { await loadRoster() } }
        }
    }

    private func loadRoster() async {
        do {
            participants = try await controller.meetingParticipants(meetingID: meeting.id)
            roles = try controller.meetingIdentityRoles(meetingID: meeting.id)
        } catch { self.error = error.localizedDescription }
    }

    private func change(_ key: MeetingSpeakerKey, participantID: String? = nil, isOwner: Bool = false,
                        automatic: Bool = false, retainName: Bool = false) {
        do {
            try controller.assignMeetingSpeaker(meetingID: meeting.id, key: key, participantID: participantID,
                                                isOwner: isOwner, automatic: automatic, retainName: retainName)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
