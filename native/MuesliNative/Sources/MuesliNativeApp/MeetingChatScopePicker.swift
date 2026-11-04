import SwiftUI
import AIElementsSwift
import MuesliCore

struct MeetingChatScopePicker: View {
    let scope: MeetingChatScope
    let folders: [MeetingFolder]
    let meetings: [MeetingChatSourceChoice]
    let onChange: (MeetingChatScope) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 2
    @State private var folderID: Int64?
    @State private var selected = Set<Int64>()
    @State private var query = ""
    @State private var datesEnabled = false
    @State private var start = Date()
    @State private var end = Date()
    private var dateBounds: ClosedRange<Date> { MeetingChatScopePolicy.dateBounds(meetings: meetings) }
    private func bounded(_ date: Date) -> Date { min(max(Calendar.current.startOfDay(for: date), dateBounds.lowerBound), dateBounds.upperBound) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label { Text("Meeting context") } icon: { AIIcon(.archive, size: 20) }.font(MuesliTheme.title2())
            Text("Choose the meetings this conversation can search. Earlier answers keep their original sources.")
                .font(MuesliTheme.font(.callout)).foregroundStyle(.secondary)
            Picker("Search", selection: $mode) {
                Text("All saved meetings").tag(0); Text("Folder").tag(1); Text("Specific meetings").tag(2)
            }.pickerStyle(.segmented)
            if mode == 1 {
                Picker("Folder", selection: $folderID) {
                    Text("Choose a folder").tag(Int64?.none)
                    ForEach(folders) { Text($0.name).tag(Optional($0.id)) }
                }
                Text("This folder only; subfolders are excluded.").font(MuesliTheme.font(.caption)).foregroundStyle(.secondary)
            }
            if mode == 2 {
                HStack { AIIcon(.search).foregroundStyle(.secondary); TextField("Find meetings by title", text: $query).textFieldStyle(.plain) }
                    .padding(10).background(MuesliTheme.backgroundRaised, in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Text(selected.isEmpty ? "No meetings selected" : "\(selected.count) selected")
                        .font(MuesliTheme.font(size: 12)).foregroundStyle(MuesliTheme.textSecondary)
                    Spacer()
                    if !selected.isEmpty {
                        Button("Clear selection") { selected.removeAll(); datesEnabled = false }
                            .buttonStyle(.muesli(.quiet)).font(MuesliTheme.font(size: 12)).frame(minHeight: 28)
                    }
                }
                List(meetings.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { meeting in
                    Toggle(isOn: Binding(get: { selected.contains(meeting.id) }, set: { if $0 { selected.insert(meeting.id) } else { selected.remove(meeting.id) } })) {
                        VStack(alignment: .leading) { Text(meeting.title); Text(meeting.startDate.formatted(date: .abbreviated, time: .shortened)).font(MuesliTheme.font(.caption)).foregroundStyle(.secondary) }
                    }.toggleStyle(.checkbox)
                }.frame(height: 240)
            }
            Toggle("Date range", isOn: $datesEnabled).disabled(meetings.isEmpty)
            if datesEnabled {
                HStack {
                    DatePicker("From", selection: $start, in: dateBounds, displayedComponents: .date)
                    DatePicker("Through", selection: $end, in: dateBounds, displayedComponents: .date)
                }
                .onChange(of: start) { _, value in if end < value { end = value } }
                .onChange(of: end) { _, value in if start > value { start = value } }
            }
            HStack {
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    let selection: MeetingChatSelection
                    if mode == 1 { guard let folderID else { return }; selection = .folder(folderID) }
                    else { selection = mode == 2 ? .meetings(selected.sorted()) : .all }
                    let filtersEnabled = datesEnabled && !(mode == 2 && selected.isEmpty)
                    let candidate = MeetingChatScope(selection: selection, startDate: filtersEnabled ? Calendar.current.startOfDay(for: start) : nil,
                        endDateExclusive: filtersEnabled ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end)) : nil)
                    guard MeetingChatScopePolicy.validDates(candidate) else { return }
                    onChange(candidate)
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled((mode == 1 && folderID == nil) || (datesEnabled && end < start))
            }
        }
        .padding(24).frame(width: 580)
        .onAppear {
            switch scope.selection { case .all: mode = 0; case .folder(let id): mode = 1; folderID = id; case .meetings(let ids): mode = 2; selected = Set(ids) }
            datesEnabled = !meetings.isEmpty && (scope.startDate != nil || scope.endDateExclusive != nil)
            start = bounded(scope.startDate ?? Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date()))!)
            end = bounded(scope.endDateExclusive.map { $0.addingTimeInterval(-1) } ?? Date())
            if start > end { start = end }
        }
    }
}
