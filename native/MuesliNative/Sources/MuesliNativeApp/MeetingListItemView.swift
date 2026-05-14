import SwiftUI
import MuesliCore

struct MeetingListItemView: View {
    let record: MeetingRecord
    let isSelected: Bool
    let folders: [MeetingFolder]
    let onSelect: () -> Void
    let onMove: (Int64?) -> Void
    let onCreateFolderAndMove: ((String) -> Void)?
    let onDelete: (() -> Void)?
    @State private var isHovering = false
    @State private var showDeleteConfirmation = false
    @State private var showFolderPopover = false
    @State private var showNewFolderPrompt = false
    @State private var newFolderName = ""

    private var currentFolderName: String? {
        guard let fid = record.folderID else { return nil }
        return folders.first(where: { $0.id == fid })?.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(alignment: .top) {
                Text(record.title)
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .lineLimit(2)

                Spacer(minLength: 4)

                HStack(spacing: 6) {
                    if !folders.isEmpty {
                        folderMenuButton
                    }
                    if onDelete != nil {
                        deleteButton
                    }
                }
            }

            HStack(spacing: MuesliTheme.spacing4) {
                if record.status != .completed {
                    statusBadge
                    Text("\u{2022}")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
                Text(formatMeta())
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)

                // Current folder badge
                if let name = currentFolderName {
                    Text("\u{2022}")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                    HStack(spacing: 2) {
                        Image(systemName: "folder")
                            .font(.system(size: 9))
                        Text(name)
                            .font(MuesliTheme.caption())
                    }
                    .foregroundStyle(MuesliTheme.accent.opacity(0.8))
                }
            }

            if let participantLine = MeetingListItemMetadata.participantLine(from: record) {
                HStack(spacing: 5) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 10, weight: .medium))
                    Text(participantLine)
                        .font(MuesliTheme.caption())
                        .lineLimit(1)
                }
                .foregroundStyle(MuesliTheme.textSecondary)
                .help(MeetingListItemMetadata.fullParticipantLine(from: record) ?? participantLine)
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(MuesliTheme.textTertiary)
                Text(MeetingListItemMetadata.notesPreview(from: record))
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .lineLimit(2)
            }
        }
        .padding(MuesliTheme.spacing16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? MuesliTheme.surfaceSelected : MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge)
                .strokeBorder(
                    isSelected ? MuesliTheme.accent.opacity(0.35) : MuesliTheme.surfaceBorder,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .alert("Delete Meeting", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { onDelete?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this meeting? Saved notes, transcript, and any retained recording will be removed.")
        }
    }

    // MARK: - Folder menu button

    @ViewBuilder
    private var folderMenuButton: some View {
        Button {
            showFolderPopover.toggle()
        } label: {
            Image(systemName: record.folderID != nil ? "folder.fill" : "folder.badge.plus")
                .font(.system(size: 11))
                .foregroundStyle(
                    record.folderID != nil
                        ? MuesliTheme.accent
                        : (isHovering ? MuesliTheme.textSecondary : MuesliTheme.textTertiary)
                )
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Move to folder")
        .popover(isPresented: $showFolderPopover, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 0) {
                folderPopoverRow(icon: "tray", label: "Unfiled", isActive: record.folderID == nil) {
                    onMove(nil)
                    showFolderPopover = false
                }
                Divider().padding(.vertical, 4)
                ForEach(folders) { folder in
                    folderPopoverRow(icon: "folder", label: folder.name, isActive: record.folderID == folder.id) {
                        onMove(folder.id)
                        showFolderPopover = false
                    }
                }
                if onCreateFolderAndMove != nil {
                    Divider().padding(.vertical, 4)
                    folderPopoverRow(icon: "folder.badge.plus", label: "New Folder...") {
                        showFolderPopover = false
                        newFolderName = ""
                        showNewFolderPrompt = true
                    }
                }
            }
            .padding(8)
        }
        .alert("New Folder", isPresented: $showNewFolderPrompt) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    onCreateFolderAndMove?(trimmed)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create a new folder and move this meeting into it.")
        }
    }

    @ViewBuilder
    private func folderPopoverRow(icon: String, label: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 16)
                Text(label)
                    .font(MuesliTheme.callout())
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MuesliTheme.accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var deleteButton: some View {
        Button {
            showDeleteConfirmation = true
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 11))
                .foregroundStyle(
                    isHovering
                        ? MuesliTheme.recording.opacity(0.85)
                        : MuesliTheme.textTertiary
                )
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isHovering ? 1 : 0)
        .help("Delete meeting")
    }

    // MARK: - Formatting

    private var statusBadge: some View {
        Text(record.status.displayLabel)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(record.status.displayColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(record.status.displayColor.opacity(0.12))
            .clipShape(Capsule())
    }

    private func formatMeta() -> String {
        let time = MeetingListItemMetadata.friendlyDate(record.startTime)
        let duration = formatDuration(record.durationSeconds)
        return "\(time)  \u{2022}  \(duration)"
    }

    private func formatDuration(_ seconds: Double) -> String {
        let rounded = Int(seconds.rounded())
        if rounded >= 3600 {
            return "\(rounded / 3600)h \((rounded % 3600) / 60)m"
        }
        if rounded >= 60 {
            let m = rounded / 60
            let s = rounded % 60
            return s == 0 ? "\(m)m" : "\(m)m \(s)s"
        }
        return "\(rounded)s"
    }

}
