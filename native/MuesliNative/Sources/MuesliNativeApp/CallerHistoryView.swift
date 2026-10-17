import MuesliCore
import SwiftUI

struct CallerHistorySelection: Identifiable, Equatable {
    let id: UUID
}

/// A caller identified from Phone app calls: their name, the numbers or
/// emails they called from, and every recording they were on.
struct CallerHistoryView: View {
    private static let historyPageSize = 50

    let personID: UUID
    let controller: MuesliController
    let onOpenMeeting: (Int64) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var person: CallerPerson?
    @State private var history: [CallerHistoryEntry] = []
    @State private var hasMoreHistory = false
    @State private var isLoadingOlderHistory = false
    @State private var name = ""
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var canSaveName = false
    @State private var isSavingName = false
    @State private var nameSaveGate = CallerNameSaveGate()
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            Text("Caller History")
                .font(MuesliTheme.headline())

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .disabled(isLoading || isSavingName || !canSaveName)
                .onSubmit { Task { await saveName() } }
                .onChange(of: isNameFocused) { _, focused in
                    if !focused { Task { await saveName() } }
                }

            if let person {
                ForEach(person.handles, id: \.key) { handle in
                    Label(handle.displayValue, systemImage: handle.kind == .phone ? "phone" : "envelope")
                        .font(MuesliTheme.callout())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .textSelection(.enabled)
                }
            }

            Text("Recordings")
                .font(MuesliTheme.captionMedium())
                .foregroundStyle(MuesliTheme.textTertiary)

            if hasMoreHistory {
                Button(isLoadingOlderHistory ? "Loading…" : "Show Older Recordings") {
                    Task { await loadOlderHistory() }
                }
                .disabled(isLoadingOlderHistory)
            }

            if history.isEmpty {
                Text("No recordings yet.")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textTertiary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        ForEach(history, id: \.meetingID) { entry in
                            Button {
                                onOpenMeeting(entry.meetingID)
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.title)
                                        .font(MuesliTheme.callout())
                                    Text(Self.formattedDate(entry.startedAt))
                                        .font(MuesliTheme.caption())
                                        .foregroundStyle(MuesliTheme.textTertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Done") {
                    Task {
                        if await saveName() {
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isLoading || isSavingName)
            }
        }
        .padding(MuesliTheme.spacing16)
        .frame(width: 360)
        .task(id: personID) {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        canSaveName = false
        person = nil
        history = []
        hasMoreHistory = false
        isLoadingOlderHistory = false
        name = ""
        errorMessage = nil
        defer { isLoading = false }
        do {
            person = try await controller.callerPerson(id: personID)
            name = person?.displayName ?? ""
            canSaveName = true
            let page = try await controller.callerHistory(
                personID: personID,
                limit: Self.historyPageSize + 1,
                offset: 0
            )
            history = Array(page.prefix(Self.historyPageSize))
            hasMoreHistory = page.count > Self.historyPageSize
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadOlderHistory() async {
        guard hasMoreHistory, !isLoadingOlderHistory else { return }
        isLoadingOlderHistory = true
        defer { isLoadingOlderHistory = false }
        do {
            let page = try await controller.callerHistory(
                personID: personID,
                limit: Self.historyPageSize + 1,
                offset: history.count
            )
            history.append(contentsOf: page.prefix(Self.historyPageSize))
            hasMoreHistory = page.count > Self.historyPageSize
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func saveName() async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSaveName else { return true }
        guard let person else { return true }
        guard trimmed != (person.displayName ?? "") else { return true }
        isSavingName = true
        defer { isSavingName = false }
        return await nameSaveGate.perform {
            do {
                try await controller.renameCallerPerson(id: personID, displayName: trimmed)
                self.person = CallerPerson(id: person.id, displayName: trimmed.isEmpty ? nil : trimmed, handles: person.handles)
                errorMessage = nil
                return true
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
    }

    private static func formattedDate(_ stored: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: stored) else { return stored }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
