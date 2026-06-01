import SwiftUI
import MuesliCore

/// The Speakers library: view, rename, merge, and delete saved voice profiles.
/// Modeled on `MeetingTemplatesManagerView` (the coach personas manager lives on
/// a separate branch and is not present here).
struct SpeakersManagerView: View {
    let appState: AppState
    let controller: MuesliController
    let onClose: () -> Void

    @State private var editingProfileID: String?
    @State private var draftName = ""
    @State private var profileToDelete: SpeakerProfile?
    @State private var selectedForMerge: Set<String> = []
    @State private var showMergeConfirmation = false

    private var profiles: [SpeakerProfile] { controller.speakerProfiles() }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                    if profiles.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: MuesliTheme.spacing8) {
                            ForEach(profiles) { profile in
                                profileRow(profile)
                            }
                        }
                    }
                }
                .padding(.bottom, MuesliTheme.spacing4)
            }
        }
        .padding(MuesliTheme.spacing24)
        .frame(minWidth: 720, minHeight: 480)
        .background(MuesliTheme.backgroundBase)
        .alert(
            "Delete \"\(profileToDelete?.name ?? "")\"?",
            isPresented: Binding(
                get: { profileToDelete != nil },
                set: { if !$0 { profileToDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { profileToDelete = nil }
            Button("Delete", role: .destructive) {
                if let profile = profileToDelete {
                    controller.deleteSpeakerProfile(id: profile.id)
                    selectedForMerge.remove(profile.id)
                }
                profileToDelete = nil
            }
        } message: {
            Text("This permanently removes the saved voiceprint. Past meetings keep their labels but lose the link to this speaker.")
        }
        .alert("Merge \(selectedForMerge.count) speakers?", isPresented: $showMergeConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Merge") { performMerge() }
        } message: {
            Text("Past meetings linked to the other speaker(s) will be repointed to \"\(mergeKeepName)\". This can't be undone.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Speakers")
                    .font(MuesliTheme.title2())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text("Voice profiles are stored on this device only and are used to recognize the same speaker across meetings.")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            HStack(spacing: MuesliTheme.spacing8) {
                if selectedForMerge.count >= 2 {
                    actionButton("Merge \(selectedForMerge.count)", systemImage: "arrow.triangle.merge") {
                        showMergeConfirmation = true
                    }
                }
                actionButton("Done", systemImage: "checkmark") { onClose() }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: MuesliTheme.spacing8) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 11))
                    .foregroundStyle(MuesliTheme.textTertiary)
                Text("No saved speakers yet.")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            Text("Name a speaker in a meeting transcript to create a profile. Recognition only applies to meetings recorded after that.")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(MuesliTheme.spacing12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func profileRow(_ profile: SpeakerProfile) -> some View {
        HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
            Button {
                toggleMergeSelection(profile.id)
            } label: {
                Image(systemName: selectedForMerge.contains(profile.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(selectedForMerge.contains(profile.id) ? MuesliTheme.accent : MuesliTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Select for merge")

            if editingProfileID == profile.id {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .onSubmit { commitRename(profile) }
                actionButton("Save", systemImage: "checkmark") { commitRename(profile) }
                actionButton("Cancel", systemImage: "xmark") { editingProfileID = nil }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(MuesliTheme.captionMedium())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(observationLabel(profile))
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
                Spacer()
                HStack(spacing: MuesliTheme.spacing8) {
                    actionButton("Rename", systemImage: "pencil") { beginRename(profile) }
                    actionButton("Delete", systemImage: "trash", role: .destructive) { profileToDelete = profile }
                }
            }
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(
                    selectedForMerge.contains(profile.id) ? MuesliTheme.accent.opacity(0.4) : MuesliTheme.surfaceBorder,
                    lineWidth: 1
                )
        )
    }

    private func observationLabel(_ profile: SpeakerProfile) -> String {
        let count = max(profile.observationCount, 0)
        return count == 1 ? "1 sample" : "\(count) samples"
    }

    private var mergeKeepName: String {
        guard let keepID = mergeKeepID, let keep = profiles.first(where: { $0.id == keepID }) else { return "" }
        return keep.name
    }

    /// The profile selected first / shown earliest wins as the kept profile.
    private var mergeKeepID: String? {
        profiles.first(where: { selectedForMerge.contains($0.id) })?.id
    }

    private func toggleMergeSelection(_ id: String) {
        if selectedForMerge.contains(id) {
            selectedForMerge.remove(id)
        } else {
            selectedForMerge.insert(id)
        }
    }

    private func performMerge() {
        guard let keepID = mergeKeepID else { return }
        for removeID in selectedForMerge where removeID != keepID {
            controller.mergeSpeakerProfiles(keepID: keepID, removeID: removeID)
        }
        selectedForMerge.removeAll()
    }

    private func beginRename(_ profile: SpeakerProfile) {
        editingProfileID = profile.id
        draftName = profile.name
    }

    private func commitRename(_ profile: SpeakerProfile) {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        editingProfileID = nil
        guard !trimmed.isEmpty else { return }
        controller.renameSpeakerProfile(id: profile.id, name: trimmed)
    }

    @ViewBuilder
    private func actionButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let isDestructive = role == .destructive
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(isDestructive ? MuesliTheme.recording : MuesliTheme.textPrimary)
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, 7)
            .background(isDestructive ? MuesliTheme.recording.opacity(0.1) : MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(
                        isDestructive ? MuesliTheme.recording.opacity(0.2) : MuesliTheme.surfaceBorder,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
