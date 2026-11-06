import SwiftUI
import MuesliCore

struct TimeTurnerTodosView: View {
    @Bindable var appState: AppState
    let controller: MuesliController
    @State private var items: [TimeTurnerRecapStore.Todo] = []
    @State private var loaded = false
    @State private var showCompleted = false
    @State private var error: String?
    @State private var revision = UUID()
    @State private var pendingDeletion: TimeTurnerRecapStore.Todo?
    @State private var deletingIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Open to-dos").font(MuesliTheme.font(size: 18, weight: .semibold))
                Spacer()
                Text("Newest first").font(MuesliTheme.caption()).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.secondary) }
            if !loaded { ProgressView() }
            else if items.allSatisfy(\.completed) {
                Text("No open to-dos. Follow-ups from saved recaps appear here.").font(MuesliTheme.body())
            }
            ForEach(items.filter { !$0.completed }) { row($0) }
            let completed = items.filter(\.completed)
            if !completed.isEmpty {
                DisclosureGroup("Completed (\(completed.count))", isExpanded: $showCompleted) {
                    ForEach(completed) { row($0) }
                }
            }
        }
        .padding(18)
        .background(MuesliTheme.backgroundRaised, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: 820, alignment: .leading)
        .alert("Delete to-do?", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { item in
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) { delete(item) }
        } message: { _ in
            Text("This removes the to-do and its reminders. Your recap is kept.")
        }
        .task(id: revision) {
            let db = controller.timeTurnerRecapDatabaseURL
            let root = controller.visualMemory.store?.root
            do {
                let result = try await Task.detached(priority: .utility) {
                    try TimeTurnerRecapStore(databaseURL: db).todos(root: root, databaseURL: db)
                }.value
                guard !Task.isCancelled else { return }
                items = result
                error = nil
            } catch { if !Task.isCancelled { items = []; self.error = error.localizedDescription } }
            loaded = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .timeTurnerTodosChanged)) { _ in revision = UUID() }
        .onReceive(DistributedNotificationCenter.default().publisher(for: MuesliNotifications.dataDidChange)) { _ in revision = UUID() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in revision = UUID() }
    }

    private func delete(_ item: TimeTurnerRecapStore.Todo) {
        guard deletingIDs.insert(item.id).inserted else { return }
        pendingDeletion = nil
        let db = controller.timeTurnerRecapDatabaseURL
        Task {
            defer { deletingIDs.remove(item.id) }
            do {
                try await Task.detached(priority: .utility) {
                    try TimeTurnerRecapStore(databaseURL: db).deleteTodo(item.id)
                }.value
                items.removeAll { $0.id == item.id }
                NotificationCenter.default.post(name: .timeTurnerTodosChanged, object: nil)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func snooze(_ item: TimeTurnerRecapStore.Todo, hours: Double?) {
        let db = controller.timeTurnerRecapDatabaseURL
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    try TimeTurnerRecapStore(databaseURL: db).snoozeTodo(item.id, interval: hours.map { $0 * 3600 })
                }.value
                NotificationCenter.default.post(name: .timeTurnerTodosChanged, object: nil)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func row(_ item: TimeTurnerRecapStore.Todo) -> some View {
        HStack(spacing: 12) {
            Button {
                let db = controller.timeTurnerRecapDatabaseURL
                Task {
                    do {
                        try await Task.detached(priority: .utility) {
                            try TimeTurnerRecapStore(databaseURL: db).setTodo(item.id, completed: !item.completed)
                        }.value
                        NotificationCenter.default.post(name: .timeTurnerTodosChanged, object: nil)
                    } catch { self.error = error.localizedDescription }
                }
            } label: { Image(systemName: item.completed ? "checkmark.circle.fill" : "circle") }
            .buttonStyle(.plain).accessibilityLabel(item.completed ? "Reopen to-do" : "Complete to-do")
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(MuesliTheme.body()).strikethrough(item.completed)
                Text("Created " + item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(MuesliTheme.caption()).foregroundStyle(.secondary)
                if let next = item.remindAt, !item.completed {
                    Text("Reminder " + next.formatted(date: .abbreviated, time: .shortened))
                        .font(MuesliTheme.caption()).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !item.completed {
                Menu {
                    Button("Every 12 hours") { snooze(item, hours: 12) }
                    Button("Every 24 hours") { snooze(item, hours: 24) }
                    if item.remindAt != nil {
                        Divider()
                        Button("Off") { snooze(item, hours: nil) }
                    }
                } label: { Image(systemName: item.remindAt == nil ? "bell" : "bell.badge") }
                .fixedSize().accessibilityLabel("Remind me about " + item.title)
                .help("Repeats while muesli is running until completed or turned off")
            }
            Button {
                let db = controller.timeTurnerRecapDatabaseURL
                Task {
                    do {
                        if let saved = try await Task.detached(priority: .utility, operation: {
                            try TimeTurnerRecapStore(databaseURL: db, readOnly: true).load(key: item.recapKey)
                        }).value { appState.openTimeTurnerRecap(saved) } else { revision = UUID() }
                    } catch { self.error = error.localizedDescription }
                }
            } label: { Image(systemName: "arrow.up.forward.square") }
            .controlSize(.small).help("View recap").accessibilityLabel("View supporting recap")
            Button { pendingDeletion = item } label: {
                if deletingIDs.contains(item.id) {
                    ProgressView().controlSize(.small).frame(width: 28, height: 28)
                } else {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(MuesliTheme.destructiveText)
                        .frame(width: 28, height: 28)
                }
            }
            .buttonStyle(.muesli(.quiet))
            .help("Delete to-do").accessibilityLabel("Delete to-do")
        }
        .disabled(deletingIDs.contains(item.id))
        .padding(10)
        .background(appState.timeTurnerFocusedTodo == item.id ? MuesliTheme.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

extension Notification.Name {
    static let timeTurnerRecapSaved = Notification.Name("muesli.timeTurnerRecapSaved")
    static let timeTurnerTodosChanged = Notification.Name("muesli.timeTurnerTodosChanged")
}

struct RecapScheduleSettings: View {
    let controller: MuesliController
    @State private var catalog = SettingsPresentationCatalog()
    @State private var customModel = ""
    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            Text("Recap settings").font(MuesliTheme.headline())
            SettingsRow(label: "Backend") { MuesliSettingControl(controller: controller, id: "recap_provider") }
            if let selection = controller.appState.config.recapModelSelection {
                if ["ollama", "lmstudio", "custom_llm"].contains(selection.backend) {
                    SettingsRow(label: "Model") {
                        TextField("Model ID", text: $customModel)
                            .onSubmit {
                                let value = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !value.isEmpty, value.utf8.count <= 256 else { return }
                                controller.updateConfig { $0.recapModelSelection?.model = value }
                            }
                    }.task(id: selection.backend + "|" + selection.model) { customModel = selection.model }
                } else {
                    SettingsRow(label: "Model") { MuesliSettingControl(controller: controller, id: "recap_model") }
                }
                SettingsNote("Uses your existing provider connection. Meeting and Computer Use selections stay unchanged.")
            }
            Divider()
            SettingsRow(label: "Automatic recap") { MuesliSettingControl(controller: controller, id: "recap_schedule") }
            if controller.appState.config.recapSchedule != "off" {
                SettingsRow(label: "Generate at") { MuesliSettingControl(controller: controller, id: "recap_schedule_hour") }
            }
            SettingsNote("Runs while muesli is open. The notification opens your recap.")
        }.padding(18).frame(width: 480)
        .environment(\.muesliSettingDefinitions, catalog.definitions(for: controller))
    }
}
