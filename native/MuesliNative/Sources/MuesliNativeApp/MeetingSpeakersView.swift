import MuesliCore
import SwiftUI

/// "Speakers" control in the meeting header: name a diarized speaker once ("This is
/// Alex") so later meetings recognize the voice. Hidden when the meeting has no
/// diarized speakers.
struct MeetingSpeakersView: View {
    let meetingID: Int64
    let controller: MuesliController

    @State private var speakers: [MeetingSpeaker] = []
    @State private var profiles: [SpeakerProfileSummary] = []
    @State private var isPopoverPresented = false
    @State private var isPeopleSheetPresented = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if !speakers.isEmpty {
                Button {
                    isPopoverPresented = true
                } label: {
                    Label(summary, systemImage: "person.wave.2")
                        .font(MuesliTheme.callout())
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(MuesliTheme.textSecondary)
                .help("Name the speakers in this meeting")
                .accessibilityIdentifier("meeting.speakers.button")
                .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) { popover }
                .sheet(isPresented: $isPeopleSheetPresented) {
                    SpeakerProfilesView(controller: controller)
                }
            }
        }
        .task(id: meetingID) { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .meetingSpeakersDidChange)) { notification in
            if let id = notification.object as? Int64, id != meetingID { return }
            Task { await reload() }
        }
        .alert("Couldn't Name Speaker", isPresented: errorBinding) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var summary: String {
        let named = speakers.filter { $0.profileID != nil }.count
        return named == 0 ? "\(speakers.count) speakers" : "\(named)/\(speakers.count) named"
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Speakers")
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)
            Text("Name a voice once and muesli recognizes it in later meetings. Voiceprints stay on this Mac.")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(speakers) { speaker in
                MeetingSpeakerRow(
                    speaker: speaker,
                    profiles: profiles,
                    onAssign: { name in await assign(speaker, name: name) },
                    onForget: { await forget(speaker) },
                    onDelete: { await deletePerson(speaker) }
                )
            }
            Divider()
            Button("Manage People…") {
                isPopoverPresented = false
                isPeopleSheetPresented = true
            }
            .font(MuesliTheme.callout())
            .accessibilityIdentifier("meeting.speakers.managePeople")
        }
        .padding(14)
        .frame(width: 340)
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func reload() async {
        do {
            let loadedSpeakers = try await controller.meetingSpeakers(meetingID: meetingID)
            let loadedProfiles = try await controller.speakerProfiles()
            if loadedSpeakers != speakers { speakers = loadedSpeakers }
            if loadedProfiles != profiles { profiles = loadedProfiles }
        } catch {
            fputs("[speakers] failed to load meeting speakers\n", stderr)
        }
    }

    private func assign(_ speaker: MeetingSpeaker, name: String) async {
        do {
            try await controller.assignMeetingSpeaker(meetingID: meetingID, label: speaker.label, name: name)
        } catch {
            errorMessage = error.localizedDescription
        }
        await reload()
    }

    private func forget(_ speaker: MeetingSpeaker) async {
        guard let profileID = speaker.profileID else { return }
        do {
            try await controller.forgetSpeakerVoiceprints(profileID: profileID, sourceMeetingID: meetingID)
        } catch {
            errorMessage = error.localizedDescription
        }
        await reload()
    }

    private func deletePerson(_ speaker: MeetingSpeaker) async {
        guard let profileID = speaker.profileID else { return }
        do {
            try await controller.deleteSpeakerProfile(id: profileID)
        } catch {
            errorMessage = error.localizedDescription
        }
        await reload()
    }
}

private struct MeetingSpeakerRow: View {
    let speaker: MeetingSpeaker
    let profiles: [SpeakerProfileSummary]
    let onAssign: (String) async -> Void
    let onForget: () async -> Void
    let onDelete: () async -> Void

    @State private var draftName = ""
    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(MuesliTheme.font(size: 14, weight: .medium))
                    .foregroundStyle(MuesliTheme.textPrimary)
                if !speaker.hasVoiceprintSource {
                    Text("too little audio to learn")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
                Spacer()
                if speaker.profileID != nil { assignedMenu }
            }
            HStack(spacing: 6) {
                TextField("This is…", text: $draftName)
                    .font(MuesliTheme.body())
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                    .accessibilityIdentifier("meeting.speakers.nameField")
                if !profiles.isEmpty { existingProfilesMenu }
                Button("Save", action: submit)
                    .font(MuesliTheme.callout())
                    .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .confirmationDialog(
            "Delete \(speaker.profileName ?? "this person")?",
            isPresented: $isConfirmingDelete
        ) {
            Button("Delete Person", role: .destructive) { Task { await onDelete() } }
        } message: {
            Text("Removes the person and every voiceprint. Names already written into transcripts stay.")
        }
    }

    private var title: String {
        guard let name = speaker.profileName, name != speaker.label else { return speaker.label }
        return "\(speaker.label) — \(name)"
    }

    private var assignedMenu: some View {
        Menu {
            if speaker.hasVoiceprintFromMeeting {
                Button("Forget This Voiceprint") { Task { await onForget() } }
            }
            Button("Delete Person…", role: .destructive) { isConfirmingDelete = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var existingProfilesMenu: some View {
        Menu {
            ForEach(profiles) { profile in
                Button(profile.name) { Task { await onAssign(profile.name) } }
            }
        } label: {
            Image(systemName: "person.crop.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Pick an existing person")
    }

    private func submit() {
        let name = draftName
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draftName = ""
        Task { await onAssign(name) }
    }
}

/// "People" sheet: every saved speaker profile with counts, forget and delete actions.
struct SpeakerProfilesView: View {
    let controller: MuesliController

    @Environment(\.dismiss) private var dismiss
    @State private var profiles: [SpeakerProfileSummary] = []
    @State private var pendingDelete: SpeakerProfileSummary?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("People")
                .font(MuesliTheme.title2())
                .foregroundStyle(MuesliTheme.textPrimary)
            Text("Voices muesli recognizes in meetings. Voiceprints are stored only on this Mac and are never synced.")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if profiles.isEmpty {
                Text("No people yet. Name a speaker from a meeting's Speakers button.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                List(profiles) { profile in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                                .font(MuesliTheme.body())
                                .foregroundStyle(MuesliTheme.textPrimary)
                            Text(counts(profile))
                                .font(MuesliTheme.caption())
                                .foregroundStyle(MuesliTheme.textSecondary)
                        }
                        Spacer()
                        Button("Forget Voiceprints") { Task { await forget(profile) } }
                            .font(MuesliTheme.callout())
                            .disabled(profile.voiceprintCount == 0)
                        Button("Delete", role: .destructive) { pendingDelete = profile }
                            .font(MuesliTheme.callout())
                    }
                }
                .frame(minHeight: 220)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.destructiveText)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .font(MuesliTheme.callout())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { await reload() }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "person")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete Person", role: .destructive) {
                if let profile = pendingDelete { Task { await delete(profile) } }
            }
        } message: {
            Text("Removes the person and every voiceprint. Names already written into transcripts stay.")
        }
    }

    private func counts(_ profile: SpeakerProfileSummary) -> String {
        let prints = profile.voiceprintCount == 1 ? "1 voiceprint" : "\(profile.voiceprintCount) voiceprints"
        let meetings = profile.meetingCount == 1 ? "1 meeting" : "\(profile.meetingCount) meetings"
        return "\(prints) · \(meetings)"
    }

    private func reload() async {
        do {
            let loaded = try await controller.speakerProfiles()
            if loaded != profiles { profiles = loaded }
        } catch {
            errorMessage = "People could not be loaded."
        }
    }

    private func forget(_ profile: SpeakerProfileSummary) async {
        do { try await controller.forgetSpeakerVoiceprints(profileID: profile.id, sourceMeetingID: nil) } catch {
            errorMessage = error.localizedDescription
        }
        await reload()
    }

    private func delete(_ profile: SpeakerProfileSummary) async {
        pendingDelete = nil
        do { try await controller.deleteSpeakerProfile(id: profile.id) } catch {
            errorMessage = error.localizedDescription
        }
        await reload()
    }
}
