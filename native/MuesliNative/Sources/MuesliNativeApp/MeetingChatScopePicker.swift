import SwiftUI
import MuesliCore

struct MeetingChatScopePicker: View {
    let scope: MeetingChatScope
    let folders: [MeetingFolder]
    let meetings: [MeetingChatSourceChoice]
    let onChange: (MeetingChatScope) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var folderID: Int64?
    @State private var selected = Set<Int64>()
    @State private var query = ""
    @State private var datesEnabled = false
    @State private var start = Date()
    @State private var end = Date()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose meeting context").font(.title2)
            Picker("Search", selection: $mode) {
                Text("All saved meetings").tag(0); Text("Folder").tag(1); Text("Specific meetings").tag(2)
            }.pickerStyle(.segmented)
            if mode == 1 {
                Picker("Folder", selection: $folderID) {
                    Text("Choose a folder").tag(Int64?.none)
                    ForEach(folders) { Text($0.name).tag(Optional($0.id)) }
                }
                Text("This folder only; subfolders are excluded.").font(.caption).foregroundStyle(.secondary)
            }
            if mode == 2 {
                TextField("Find meetings by title", text: $query)
                List(meetings.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { meeting in
                    Toggle(isOn: Binding(get: { selected.contains(meeting.id) }, set: { if $0 { selected.insert(meeting.id) } else { selected.remove(meeting.id) } })) {
                        VStack(alignment: .leading) { Text(meeting.title); Text(meeting.startDate.formatted()).font(.caption).foregroundStyle(.secondary) }
                    }.toggleStyle(.checkbox)
                }.frame(height: 240)
            }
            Toggle("Date range", isOn: $datesEnabled)
            if datesEnabled { HStack { DatePicker("From", selection: $start, displayedComponents: .date); DatePicker("Through", selection: $end, displayedComponents: .date) } }
            HStack {
                Spacer(); Button("Cancel") { dismiss() }
                Button("Apply") {
                    let selection: MeetingChatSelection = mode == 1 ? .folder(folderID!) : mode == 2 ? .meetings(selected.sorted()) : .all
                    onChange(.init(selection: selection, startDate: datesEnabled ? Calendar.current.startOfDay(for: start) : nil,
                        endDateExclusive: datesEnabled ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end)) : nil))
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled((mode == 1 && folderID == nil) || (mode == 2 && selected.isEmpty) || (datesEnabled && end < start))
            }
        }
        .padding(24).frame(width: 580)
        .onAppear {
            switch scope.selection { case .all: mode = 0; case .folder(let id): mode = 1; folderID = id; case .meetings(let ids): mode = 2; selected = Set(ids) }
            datesEnabled = scope.startDate != nil || scope.endDateExclusive != nil
            start = scope.startDate ?? Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date()))!
            end = scope.endDateExclusive.map { $0.addingTimeInterval(-1) } ?? Date()
        }
    }
}
