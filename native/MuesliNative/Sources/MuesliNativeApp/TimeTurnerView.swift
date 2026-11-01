import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import MuesliCore

@MainActor private enum MemoryPreviewCache {
    static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        cache.countLimit = 80
        return cache
    }()
}

struct MemoryImageView: View {
    let item: VisualMemoryItem
    let memory: VisualMemoryController
    var maximumSize: CGFloat = 400
    var compact = false
    @State private var image: NSImage?
    @State private var unavailable = false
    var body: some View {
        Group {
            if compact && (item.mediaDeletedAt != nil || unavailable) {
                Label(item.mediaDeletedAt != nil ? "Screenshot expired" : "Preview unavailable", systemImage: "photo")
                    .font(MuesliTheme.caption()).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            else if item.mediaDeletedAt != nil {
                VStack(spacing: 12) {
                    Label("Screenshot expired", systemImage: "text.page")
                    Text(item.text.isEmpty ? "App history is still available." : item.text)
                        .lineLimit(12).textSelection(.enabled)
                }.font(MuesliTheme.body()).padding(20)
            }
            else if let image { Image(nsImage: image).resizable().scaledToFit() }
            else if unavailable { Label("Capture unavailable or incomplete", systemImage: "photo.badge.exclamationmark").font(MuesliTheme.font(.caption)).multilineTextAlignment(.center) }
            else { ProgressView().controlSize(.small) }
        }
        .task(id: item.id + item.path + String(describing: item.mediaDeletedAt)) {
            image = nil; unavailable = false
            guard let url = memory.mediaURL(item) else { unavailable = true; return }
            let key = "\(item.path):\(item.frameIndex ?? -1):\(maximumSize)" as NSString
            if let cached = MemoryPreviewCache.images.object(forKey: key) { image = cached; return }
            do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            let index = item.frameIndex, size = maximumSize
            let loaded = await Task.detached(priority: .utility) { () -> NSImage? in
                if let index {
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: size, height: size)
                    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
                    guard let cg = try? generator.copyCGImage(at: CMTime(value: Int64(index), timescale: 1), actualTime: nil) else { return nil }
                    return NSImage(cgImage: cg, size: .zero)
                }
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width >= 100, height >= 100,
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: size
                      ] as CFDictionary) else { return nil }
                return NSImage(cgImage: cg, size: .zero)
            }.value
            guard !Task.isCancelled else { return }
            image = loaded; unavailable = loaded == nil
            if let loaded {
                MemoryPreviewCache.images.setObject(loaded, forKey: key, cost: Int(maximumSize * maximumSize * 4))
            }
        }
    }
}

struct TimeTurnerControls: View {
    let controller: MuesliController
    let appState: AppState
    @Binding var isExpanded: Bool
    var standalone = false
    @State private var showsSettings = false
    @State private var showsSetup = false
    private var memory: VisualMemoryController { controller.visualMemory }
    var body: some View {
        HStack {
            if !standalone {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).frame(width: 12)
                    Label { Text("Time Turner") } icon: { Image(nsImage: TimeTurnerIcon.image()) }.font(MuesliTheme.font(.headline))
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse Time Turner" : "Expand Time Turner")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            }
            Text(memory.ambientStatus)
                .font(MuesliTheme.font(.caption)).foregroundStyle(.secondary).lineLimit(1)
                .help(memory.ambientStatus == "Skipping this app" ? "The current app is excluded from screen capture. Capture resumes when you switch to an allowed app." : memory.ambientStatus)
            if !standalone { Spacer() }
            if appState.config.timeTurnerEnabled {
                RecordingPauseButton(isPaused: memory.ambientPaused) { memory.toggleAmbientPause() }
                    .help(memory.ambientPaused ? "Resume screen history" : "Pause screen history")
            }
            if !appState.config.timeTurnerEnabled {
                Button("Set up Time Turner") { showsSetup = true }
            }
            Button { showsSettings = true } label: {
                if standalone { Image(systemName: "gearshape") }
                else { Text("Settings…") }
            }.accessibilityLabel("Time Turner settings").help("Time Turner settings")
        }
        .task {
            memory.configureAmbient(appState.config, audioFallbackActive: appState.isMeetingRecording && !appState.config.useCoreAudioTap)
        }
        .padding(standalone ? 0 : 12)
        .background(standalone ? Color.clear : MuesliTheme.backgroundRaised, in: RoundedRectangle(cornerRadius: 10))
        .sheet(isPresented: $showsSettings) {
            VStack(spacing: 0) {
                HStack {
                    Text("Time Turner").font(MuesliTheme.font(.title2).bold())
                    Spacer()
                    Button("Open in Settings") {
                        showsSettings = false
                        appState.selectedSettingsPane = .experimental
                        controller.openSettingsTab()
                    }
                    Button("Done") { showsSettings = false }.keyboardShortcut(.cancelAction)
                }.padding(20)
                ScrollView { TimeTurnerSettingsView(controller: controller, appState: appState).padding(20) }
            }.frame(width: 680, height: 650)
        }
        .sheet(isPresented: $showsSetup) { TimeTurnerSetupView(controller: controller, appState: appState) }
    }
}

/// A native mouse tracking surface keeps scrubbing independent of the page's
/// vertical scroll gestures. Coordinates always use the whole track's bounds.
private struct MemoryScrubSurface: NSViewRepresentable {
    var onScrub: (Double) -> Void
    func makeNSView(context: Context) -> ScrubView { ScrubView() }
    func updateNSView(_ view: ScrubView, context: Context) { view.onScrub = onScrub }
    final class ScrubView: NSView {
        var onScrub: ((Double) -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { scrub(event) }
        override func mouseDragged(with event: NSEvent) { scrub(event) }
        override func mouseUp(with event: NSEvent) { scrub(event) }
        private func scrub(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            onScrub?(Double(min(1, max(0, point.x / max(1, bounds.width)))))
        }
    }
}

struct MemoryExplorerView: View {
    let externalDay: Binding<Date>?
    let memory: VisualMemoryController
    @Environment(\.dismiss) private var dismiss
    @State private var dayMoments: [VisualMemoryItem] = []
    @State private var day: Date
    @State private var playhead: Date
    @State private var selectedCaptureID: String?
    @State private var showsSearch = false
    let inline: Bool
    let onNavigate: ((Date, Date) -> Void)?
    let focusedSize: CGSize?
    let onClose: (() -> Void)?
    private var focusPresenter: TimeTurnerFocusPresenter { .shared }
    @State private var lastHapticTime = Date.distantPast
    init(initialMoment: VisualMemoryItem?, memory: VisualMemoryController, inline: Bool = false, externalDay: Binding<Date>? = nil, focusedSize: CGSize? = nil, onClose: (() -> Void)? = nil, onNavigate: ((Date, Date) -> Void)? = nil) {
        self.memory = memory
        self.externalDay = externalDay
        self.inline = inline
        self.focusedSize = focusedSize
        self.onClose = onClose
        self.onNavigate = onNavigate
        let selectedDay = externalDay?.wrappedValue ?? initialMoment?.capturedAt ?? Date()
        let initial = initialMoment.flatMap { Calendar.current.isDate($0.capturedAt, inSameDayAs: selectedDay) ? $0 : nil }
        _day = State(initialValue: selectedDay)
        _playhead = State(initialValue: initial?.capturedAt ?? selectedDay)
        _selectedCaptureID = State(initialValue: initial?.id)
    }
    @State private var confirmForget = false
    @State private var showsText = false
    private func expandExplorer() {
        guard inline, let selected else { return }
        focusPresenter.present(owner: NSApp.keyWindow, moment: selected, memory: memory) { date, time in
            day = date
            selectedCaptureID = nil
            playhead = time
        }
    }
    private func closeExplorer() { if let onClose { onClose() } else { dismiss() } }
    private var ordered: [VisualMemoryItem] { dayMoments }
    private var index: Int {
        if let selectedCaptureID, let exact = ordered.firstIndex(where: { $0.id == selectedCaptureID }) { return exact }
        return VisualMemoryDayTimeline.nearestIndex(in: ordered, to: playhead) ?? 0
    }
    private var dayInterval: DateInterval { Calendar.current.dateInterval(of: .day, for: day)! }
    private var scrubInterval: DateInterval { VisualMemoryDayTimeline.captureInterval(in: ordered) ?? DateInterval(start: dayInterval.start, duration: 1) }
    @State private var scrubScale = VisualMemoryScrubScale(dates: [])
    private var appNames: [String] { Array(Set(ordered.map(\.bundleID))).sorted() }
    private func select(_ offset: Int) { guard ordered.indices.contains(offset) else { return }; selectedCaptureID = ordered[offset].id; playhead = ordered[offset].capturedAt }
    private func moveDay(_ amount: Int) { if let next = Calendar.current.date(byAdding: .day, value: amount, to: day) { day = next } }
    private func appIcon(_ item: VisualMemoryItem, size: CGFloat = 22) -> some View {
        TargetApplicationIconView(appName: item.source, bundleIdentifier: item.bundleID, size: size)
            .accessibilityLabel(item.source).help(item.source)
    }
    @State private var trackWidth: CGFloat = 800
    private struct AppMarker: Identifiable {
        let item: VisualMemoryItem
        let x: CGFloat
        let lane: Int
        var id: String { item.id }
    }
    // Keep a single icon row; all captures remain reachable through the scrubber.
    // The current app is always visible in the header, including dense sections.
    private func iconMarkers(width: CGFloat) -> [AppMarker] {
        let scale = scrubScale
        var markers: [AppMarker] = []
        var previousBundle: String?
        for item in ordered {
            defer { previousBundle = item.bundleID }
            guard item.bundleID != previousBundle else { continue }
            let x = min(max(14, width - 14), max(14, scale.fraction(for: item.capturedAt) * width))
            guard markers.last.map({ x - $0.x >= 30 }) ?? true else { continue }
            markers.append(AppMarker(item: item, x: x, lane: 0))
        }
        return markers
    }
    private var trackHeight: CGFloat { 34 }
    private var selected: VisualMemoryItem? { ordered.indices.contains(index) ? ordered[index] : nil }
    private var dayScrubber: some View {
        let scale = scrubScale
        return VStack(spacing: 8) {
            HStack {
                Text(playhead.formatted(date: .omitted, time: .standard)).monospacedDigit()
                if let selected, abs(selected.capturedAt.timeIntervalSince(playhead)) > 120 {
                    Text("Gap · showing nearest capture at \(selected.capturedAt.formatted(date: .omitted, time: .standard))").foregroundStyle(.secondary)
                }
                if scale.compressesGaps { Text("Gaps compressed").foregroundStyle(.secondary).help("Long gaps use less space. Timestamps remain exact.") }
                Spacer()
                Button { select(max(0, index - 1)) } label: { Image(systemName: "chevron.left") }
                    .disabled(index == 0).accessibilityLabel("Previous moment").keyboardShortcut(.leftArrow, modifiers: [])
                Text("\(index + 1) / \(ordered.count)").monospacedDigit().foregroundStyle(.secondary)
                Button { select(min(ordered.count - 1, index + 1)) } label: { Image(systemName: "chevron.right") }
                    .disabled(index == ordered.count - 1).accessibilityLabel("Next moment").keyboardShortcut(.rightArrow, modifiers: [])
            }.font(MuesliTheme.font(.caption))
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Capsule().fill(.primary.opacity(0.07)).frame(height: 4).offset(y: 14)
                    Canvas { context, size in
                        for (offset, item) in ordered.enumerated() {
                            let x = min(max(0, size.width - 2), scale.fraction(for: item.capturedAt) * size.width)
                            let next = offset + 1 < ordered.count ? ordered[offset + 1].capturedAt : item.capturedAt.addingTimeInterval(1)
                            let duration = min(120, max(1, next.timeIntervalSince(item.capturedAt)))
                            let width = max(2, (scale.fraction(for: item.capturedAt.addingTimeInterval(duration)) - scale.fraction(for: item.capturedAt)) * size.width)
                            context.fill(Path(roundedRect: CGRect(x: x, y: 14, width: min(width, size.width - x), height: 4), cornerRadius: 3), with: .color(.primary.opacity(0.25)))
                        }
                    }
                    ForEach(iconMarkers(width: geometry.size.width)) { marker in
                        appIcon(marker.item)
                            .padding(3)
                            .background(MuesliTheme.backgroundRaised, in: RoundedRectangle(cornerRadius: 7))
                            .offset(x: marker.x - 14, y: CGFloat(marker.lane) * 30)
                            .allowsHitTesting(false)
                    }
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 3, height: trackHeight)
                        .offset(x: max(0, min(geometry.size.width - 3, scale.fraction(for: playhead) * geometry.size.width)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onAppear { trackWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, width in trackWidth = width }
                .contentShape(Rectangle())
                .overlay {
                    MemoryScrubSurface { fraction in
                        let nextTime = scale.date(at: fraction) ?? playhead
                        let nextIndex = VisualMemoryDayTimeline.nearestIndex(in: ordered, to: nextTime)
                        if let nextIndex, ordered[nextIndex].bundleID != selected?.bundleID,
                           Date().timeIntervalSince(lastHapticTime) > 0.08 {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                            lastHapticTime = Date()
                        }
                        selectedCaptureID = nil
                        playhead = nextTime
                    }
                }
                .accessibilityElement().accessibilityLabel("Scrub entire day across apps")
                .accessibilityValue(playhead.formatted(date: .omitted, time: .standard))
                .accessibilityAdjustableAction { direction in
                    if direction == .increment { select(min(ordered.count - 1, index + 1)) }
                    else if direction == .decrement { select(max(0, index - 1)) }
                }
            }.frame(height: trackHeight)
            HStack {
                ForEach(0..<5) { tick in
                    if tick > 0 { Spacer() }
                    Text((scale.date(at: Double(tick) / 4) ?? scrubInterval.start).formatted(date: .omitted, time: scrubInterval.duration < 300 ? .standard : .shortened))
                }
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
    var body: some View { explorerContent }
    private var explorerContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if !inline {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(Color.accentColor)
                    Text("Time Turner").font(MuesliTheme.font(size: 16, weight: .semibold))
                } else if let selected {
                    appIcon(selected, size: 20)
                    Text(selected.source.trimmingCharacters(in: CharacterSet(charactersIn: " ·")))
                        .font(MuesliTheme.font(.caption)).lineLimit(1).frame(maxWidth: 220, alignment: .leading)
                }
                Spacer()
                if externalDay == nil {
                HStack(spacing: 8) {
                Button { moveDay(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous day")
                DatePicker("Day", selection: $day, in: ...Date(), displayedComponents: .date).labelsHidden().fixedSize()
                Button { moveDay(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next day").disabled(Calendar.current.isDateInToday(day))
                }
                .padding(inline ? 0 : 6)
                .modifier(TimeTurnerControlSurface(enabled: !inline))
                }
                Spacer()
                Button { showsSearch.toggle() } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("Search screen history")
                    .help("Search by text, app, and date")
                    .popover(isPresented: $showsSearch) {
                        TimeTurnerSearchView(memory: memory, initialDay: day) { item in
                            day = item.capturedAt
                            dayMoments = [item]
                            scrubScale = VisualMemoryScrubScale(dates: [item.capturedAt])
                            selectedCaptureID = item.id
                            playhead = item.capturedAt
                            showsSearch = false
                        }
                    }
                Label("On this Mac", systemImage: "lock").font(MuesliTheme.font(.caption)).foregroundStyle(.secondary)
                if inline {
                    Button { expandExplorer() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 26, height: 26) }
                        .buttonStyle(.plain).accessibilityLabel("Expand screen history").disabled(selected == nil)
                } else {
                    Button { closeExplorer() } label: { Image(systemName: "xmark").frame(width: 26, height: 26) }
                        .modifier(TimeTurnerGlassButtons(enabled: true)).accessibilityLabel("Close screen history").keyboardShortcut(.cancelAction)
                }
            }.modifier(TimeTurnerGlassButtons(enabled: !inline))
                .padding(.horizontal, 24).padding(.vertical, 16)
            if let selected {
                HStack(alignment: .top, spacing: 0) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.08))
                        MemoryImageView(item: selected, memory: memory, maximumSize: inline ? 1800 : 3000)
                            .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
                        if !inline {
                        HStack(spacing: 12) {
                            Image(systemName: "macwindow")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(selected.source.trimmingCharacters(in: CharacterSet(charactersIn: " ·"))).lineLimit(1).font(MuesliTheme.font(size: 12, weight: .medium))
                                Text(selected.capturedAt.formatted(date: .abbreviated, time: .standard)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button { if inline { expandExplorer() } else { showsText.toggle() } } label: { Image(systemName: "text.viewfinder").frame(width: 28, height: 28) }
                                .help("Show captured text").accessibilityLabel("Show captured text")
                            Menu {
                                Button("Forget this chunk…", role: .destructive) { confirmForget = true }
                            } label: { Image(systemName: "ellipsis").frame(width: 20) }.menuStyle(.borderlessButton).fixedSize()
                        }
                        .padding(12).modifier(TimeTurnerControlSurface(enabled: true))
                        .modifier(TimeTurnerGlassButtons(enabled: true))
                        .padding(18)
                        }
                    }
                    .onTapGesture(count: 2) { if inline { expandExplorer() } }
                    if showsText {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Captured text").font(MuesliTheme.font(.headline))
                                Spacer()
                                Button { showsText = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Hide captured text")
                            }
                            ScrollView { Text(selected.text.isEmpty ? "No readable text in this moment." : selected.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            if !selected.text.isEmpty {
                                Button("Copy text") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selected.text, forType: .string) }
                            }
                        }.padding(18).frame(width: 260)
                    }
                }
                .padding(.horizontal, 20).frame(maxWidth: .infinity, maxHeight: .infinity)
                dayScrubber
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20).padding(.vertical, 12)
            } else {
                ContentUnavailableView("No captures on this day", systemImage: "calendar", description: Text("Choose another day to browse your screen history."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(day)|\(memory.catalogRevision)") {
            let moments = (try? await memory.moments(on: day)) ?? []
            guard !Task.isCancelled else { return }
            dayMoments = moments
            scrubScale = VisualMemoryScrubScale(dates: moments.map(\.capturedAt))
        }
        .onChange(of: externalDay?.wrappedValue) { _, value in
            if let value { day = value }
        }
        .onChange(of: day) { _, _ in
            externalDay?.wrappedValue = day
            dayMoments = []
            scrubScale = VisualMemoryScrubScale(dates: [])
            if !Calendar.current.isDate(playhead, inSameDayAs: day) {
                playhead = ordered.first?.capturedAt ?? dayInterval.start
            }
        }
        .onChange(of: playhead) { _, value in onNavigate?(day, value) }
        .frame(width: inline ? nil : (focusedSize?.width ?? 1000), height: inline ? (ordered.isEmpty ? 140 : 520) : (focusedSize?.height ?? 760))
        .modifier(TimeTurnerGlass(cornerRadius: inline ? 18 : 24))
        .confirmationDialog("Forget this recording chunk?", isPresented: $confirmForget) {
            Button("Delete chunk, history and recaps", role: .destructive) { if let selected { memory.delete(selected) }; closeExplorer() }
        } message: { Text("All moments sharing this archive chunk, their captured text and associated recaps will be deleted together.") }
    }
}

/// Transient search filters share the CLI's read-only SQLite retrieval contract.
private struct TimeTurnerSearchView: View {
    let memory: VisualMemoryController
    let initialDay: Date
    let onSelect: (VisualMemoryItem) -> Void
    @State private var query = ""
    @State private var app = ""
    @State private var restrictDate = false
    @State private var date = Date()
    @State private var results: [VisualMemoryItem] = []
    @State private var cursor: VisualMemoryCursor?
    @State private var loading = false
    @State private var error: String?
    @State private var page = 0
    @State private var generation = UUID()

    private var apps: [VisualMemoryController.HistoryApp] { memory.historyApps }
    private var request: String { "\(query)|\(app)|\(restrictDate)|\(restrictDate ? date.timeIntervalSince1970 : 0)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search screen history").font(MuesliTheme.font(.headline))
            TextField("Search captured text or window titles", text: $query)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Search captured text")
            HStack {
                Picker("App", selection: $app) {
                    Text("All apps").tag("")
                    ForEach(apps, id: \.id) { entry in Text(entry.name).tag(entry.id) }
                }.frame(maxWidth: 260)
                Toggle("On date", isOn: $restrictDate).toggleStyle(.checkbox)
                if restrictDate {
                    DatePicker("Capture date", selection: $date, in: ...Date(), displayedComponents: .date)
                        .labelsHidden().accessibilityLabel("Capture date")
                }
            }
            Divider()
            if let error {
                Text(error).foregroundStyle(.secondary)
                Button("Retry") { page += 1 }
            }
            if results.isEmpty && cursor == nil && !loading && error == nil {
                ContentUnavailableView("No matching captures", systemImage: "magnifyingglass",
                    description: Text("Try different words, another app, or a wider date range."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(results) { item in
                            Button { onSelect(item) } label: {
                                HStack(spacing: 12) {
                                    MemoryImageView(item: item, memory: memory, maximumSize: 200)
                                        .frame(width: 100, height: 64).clipped()
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.source).font(MuesliTheme.font(.callout).weight(.medium)).lineLimit(1)
                                        Text(item.capturedAt.formatted(date: .abbreviated, time: .standard))
                                            .font(MuesliTheme.font(.caption)).foregroundStyle(.secondary)
                                        Text(item.text).font(MuesliTheme.font(.caption)).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.up.right")
                                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .accessibilityLabel("Open \(item.source), \(item.capturedAt.formatted())")
                        }
                        if cursor != nil && !loading {
                            Button("Load more") { page += 1 }.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            if loading { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
            Text("Matches captured words and phrases · newest first")
                .font(MuesliTheme.font(.caption)).foregroundStyle(.secondary)
        }
        .padding(18).frame(width: 580, height: 460)
        .onAppear { date = initialDay }
        .task(id: request) {
            generation = UUID()
            results = []; cursor = nil
            await search(append: false)
        }
        .task(id: memory.catalogRevision) {
            await revalidateLoadedResults()
        }
        .task(id: page) {
            guard page > 0 else { return }
            await search(append: cursor != nil)
        }
    }

    /// Refresh only already loaded identities; new captures must not reset pagination.
    @MainActor private func revalidateLoadedResults() async {
        guard let store = memory.store, !results.isEmpty else { return }
        let token = generation
        let ids = results.map(\.id)
        let revision = memory.catalogRevision
        do {
            let current = try await Task.detached(priority: .utility) {
                try ids.compactMap { try store.moment(id: $0) }
            }.value
            guard !Task.isCancelled, token == generation else { return }
            guard revision == memory.catalogRevision else { return }
            // Preserve pages appended while this snapshot was being read.
            let refreshed = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
            let checked = Set(ids)
            results = results.compactMap { checked.contains($0.id) ? refreshed[$0.id] : $0 }
        } catch { /* A transient read error must not discard loaded pages. */ }
    }

    @MainActor private func search(append: Bool) async {
        let token = generation
        loading = true; error = nil
        do {
            if !append { try await Task.sleep(for: .milliseconds(250)) }
            guard let root = memory.store?.root else {
                throw NSError(domain: "TimeTurner", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Screen history is unavailable."])
            }
            let text = query, bundle = app.isEmpty ? nil : app
            let interval = restrictDate ? Calendar.current.dateInterval(of: .day, for: date) : nil
            let after = append ? cursor : nil
            let rows = try await Task.detached(priority: .userInitiated) {
                let store = try VisualMemoryStore(root: root, readOnly: true)
                return try store.searchMoments(text: text, from: interval?.start ?? .distantPast,
                    until: interval?.end ?? .distantFuture, app: bundle, limit: 51, after: after)
            }.value
            guard !Task.isCancelled, token == generation else { return }
            let batch = Array(rows.prefix(50))
            if append { results += batch } else { results = batch }
            await revalidateLoadedResults()
            guard !Task.isCancelled, token == generation else { return }
            cursor = rows.count > 50 ? batch.last.map {
                VisualMemoryCursor(capturedAtUnix: $0.capturedAt.timeIntervalSince1970, id: $0.id)
            } : nil
            loading = false
        } catch {
            guard !Task.isCancelled, token == generation else { return }
            self.error = error.localizedDescription
            loading = false
        }
    }
}

private struct TimeTurnerGlass: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(MuesliTheme.backgroundRaised, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

/// Native control glass, with legible fallbacks for older systems and accessibility.
private struct TimeTurnerGlassButtons: ViewModifier {
    let enabled: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if enabled, !reduceTransparency, #available(macOS 26.0, *) {
            content.buttonStyle(.glass).buttonBorderShape(.capsule)
        } else if enabled {
            content.buttonStyle(.bordered)
        } else {
            content
        }
    }
}

private struct TimeTurnerControlSurface: ViewModifier {
    let enabled: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if !enabled { content }
        else if reduceTransparency {
            content.background(MuesliTheme.backgroundRaised, in: RoundedRectangle(cornerRadius: 14))
        } else if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                content.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14))
            }
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}
