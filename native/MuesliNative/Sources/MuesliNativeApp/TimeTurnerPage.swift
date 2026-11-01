import SwiftUI
import MuesliCore

/// A shared day and retained navigation selection across History and Recap.
struct TimeTurnerPage: View {
    @Bindable var appState: AppState
    let controller: MuesliController
    @State private var dayMoments: [VisualMemoryItem] = []
    @State private var cachedDay: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) {
                        pageTitle
                        Spacer(minLength: 20)
                        dayControls.fixedSize()
                        captureControls.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        pageTitle
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 20) { dayControls.fixedSize(); captureControls.fixedSize() }
                            VStack(alignment: .leading, spacing: 10) { dayControls; captureControls }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 24) {
                        tab("History", recap: false)
                        tab("Recap", recap: true)
                    }
                    Divider().overlay(MuesliTheme.surfaceBorder)
                }
                if appState.timeTurnerShowsRecap {
                    TimeTurnerRecapView(day: appState.timeTurnerDay, controller: controller) { capture in
                        appState.timeTurnerDay = capture.capturedAt
                        appState.timeTurnerSelectedCapture = capture
                        appState.timeTurnerShowsRecap = false
                    }
                    .frame(maxWidth: 820, alignment: .leading)
                } else {
                    MemoryExplorerView(initialMoment: appState.timeTurnerSelectedCapture ??
                        dayMoments.last,
                        memory: controller.visualMemory, inline: true, externalDay: $appState.timeTurnerDay,
                        onNavigate: { day, time in
                            appState.timeTurnerDay = day
                            let moments = cachedDay.map { Calendar.current.isDate($0, inSameDayAs: day) } == true
                                ? dayMoments : VisualMemoryDayTimeline.moments(controller.visualMemory.historyMoments, on: day)
                            if let index = VisualMemoryDayTimeline.nearestIndex(in: moments, to: time) {
                                appState.timeTurnerSelectedCapture = moments[index]
                            }
                        })
                }
            }.padding(MuesliTheme.pageInset)
        }.task(id: "\(appState.timeTurnerDay)|\(controller.visualMemory.catalogRevision)") {
            let items = controller.visualMemory.historyMoments, day = appState.timeTurnerDay
            let moments = await Task.detached(priority: .userInitiated) {
                VisualMemoryDayTimeline.moments(items, on: day)
            }.value
            guard !Task.isCancelled else { return }
            dayMoments = moments
            cachedDay = day
        }
    }

    private var pageTitle: some View {
        Text("Time Turner").font(MuesliTheme.font(size: 26, weight: .bold)).fixedSize()
    }

    private func tab(_ title: String, recap: Bool) -> some View {
        let selected = appState.timeTurnerShowsRecap == recap
        return Button { appState.timeTurnerShowsRecap = recap } label: {
            Text(title)
                .font(MuesliTheme.font(size: 14, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? MuesliTheme.textPrimary : MuesliTheme.textSecondary)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(selected ? MuesliTheme.accent : Color.clear).frame(height: 2)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var captureControls: some View {
        TimeTurnerControls(controller: controller, appState: appState, isExpanded: .constant(true), standalone: true)
    }
    private var dayControls: some View {
        HStack(spacing: 10) {
            Button { moveDay(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous day")
            DatePicker("Day", selection: $appState.timeTurnerDay, in: ...Date(), displayedComponents: .date)
                .labelsHidden().fixedSize()
            Button { moveDay(1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("Next day").disabled(Calendar.current.isDateInToday(appState.timeTurnerDay))
        }
        .onChange(of: appState.timeTurnerDay) { _, day in
            if let capture = appState.timeTurnerSelectedCapture, !Calendar.current.isDate(capture.capturedAt, inSameDayAs: day) {
                appState.timeTurnerSelectedCapture = nil
            }
        }
    }
    private func moveDay(_ offset: Int) {
        if let day = Calendar.current.date(byAdding: .day, value: offset, to: appState.timeTurnerDay) {
            appState.timeTurnerDay = day
        }
    }
}
