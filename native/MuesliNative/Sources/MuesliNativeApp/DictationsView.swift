import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import TelemetryDeck
import MuesliCore

enum DictationFilter: Hashable {
    case all, last2Days, lastWeek, last2Weeks, lastMonth, last3Months

    var label: String {
        switch self {
        case .all: return "All time"
        case .last2Days: return "Last 2 days"
        case .lastWeek: return "Last week"
        case .last2Weeks: return "Last 2 weeks"
        case .lastMonth: return "Last month"
        case .last3Months: return "Last 3 months"
        }
    }
}

struct DictationsView: View {
    let appState: AppState
    let controller: MuesliController
    @State private var selectedFilter: DictationFilter = .all
    @State private var bridgePromptSeen = false
    @State private var isBridgeQRCodePresented = false

    private var groupedDictations: [(header: String, records: [DictationRecord])] {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        let dateHeaderFormatter: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale.current
            f.dateFormat = "EEE, d MMM"
            return f
        }()

        var groups: [(key: Date, header: String, records: [DictationRecord])] = []
        var currentDayStart: Date?
        var currentRecords: [DictationRecord] = []
        var currentHeader = ""

        for record in appState.dictationRows {
            let date = parseDate(record.timestamp) ?? now
            let dayStart = calendar.startOfDay(for: date)

            if dayStart != currentDayStart {
                if !currentRecords.isEmpty, let key = currentDayStart {
                    groups.append((key: key, header: currentHeader, records: currentRecords))
                }
                currentDayStart = dayStart
                currentRecords = []

                if dayStart == today {
                    currentHeader = "TODAY"
                } else if dayStart == yesterday {
                    currentHeader = "YESTERDAY"
                } else {
                    currentHeader = dateHeaderFormatter.string(from: date).uppercased()
                }
            }
            currentRecords.append(record)
        }
        if !currentRecords.isEmpty, let key = currentDayStart {
            groups.append((key: key, header: currentHeader, records: currentRecords))
        }

        return groups.map { (header: $0.header, records: $0.records) }
    }

    var body: some View {
        VStack(spacing: 0) {
            StatsHeaderView(
                dictationStats: appState.dictationStats,
                meetingStats: appState.meetingStats
            )

            if appState.config.showIOSCompanionPrompt {
                iPhoneBridgeCard
                    .padding(.horizontal, MuesliTheme.spacing24)
                    .padding(.bottom, MuesliTheme.spacing12)
            }

            if appState.config.resolvedOnboardingUseCase.includesVoiceNotes {
                HStack {
                    Spacer()
                    voiceNoteButton
                }
                .padding(.horizontal, MuesliTheme.spacing24)
                .padding(.bottom, MuesliTheme.spacing12)
            }

            if appState.dictationRows.isEmpty {
                Spacer()
                VStack(spacing: MuesliTheme.spacing12) {
                    Image(systemName: "mic.badge.plus")
                        .font(.system(size: 40, weight: .thin))
                        .foregroundStyle(MuesliTheme.textTertiary)
                    Text("No dictations yet")
                        .font(MuesliTheme.title3())
                        .foregroundStyle(MuesliTheme.textSecondary)
                    Text(emptyStateInstruction)
                        .font(MuesliTheme.callout())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
                        ForEach(Array(groupedDictations.enumerated()), id: \.element.header) { index, group in
                            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                                HStack {
                                    Text(group.header)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(MuesliTheme.textTertiary)
                                        .padding(.leading, MuesliTheme.spacing4)

                                    Spacer()

                                    // Filter button on the first group header
                                    if index == 0 {
                                        dateFilterButton
                                    }
                                }

                                VStack(spacing: 1) {
                                    ForEach(group.records) { record in
                                        DictationRowView(
                                            record: record,
                                            timeOnly: formatTimeOnly(record.timestamp),
                                            onCopy: {
                                                controller.copyToClipboard(record.rawText)
                                            },
                                            onCopyTrace: record.computerUseTrace == nil ? nil : {
                                                controller.copyToClipboard(ComputerUseTraceFormatter.debugText(for: record))
                                            },
                                            onDelete: {
                                                controller.deleteDictation(id: record.id)
                                            }
                                        )
                                        .contextMenu {
                                            Button {
                                                controller.copyToClipboard(record.rawText)
                                            } label: {
                                                Label("Copy", systemImage: "doc.on.doc")
                                            }
                                            if record.computerUseTrace != nil {
                                                Button {
                                                    controller.copyToClipboard(ComputerUseTraceFormatter.debugText(for: record))
                                                } label: {
                                                    Label("Copy CUA Trace", systemImage: "list.bullet.clipboard")
                                                }
                                            }
                                        }
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
                                .overlay(
                                    RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                                )
                            }
                        }

                        // Infinite scroll trigger
                        if appState.hasMoreDictations {
                            Color.clear
                                .frame(height: 1)
                                .onAppear {
                                    controller.loadMoreDictations()
                                }
                        }
                    }
                    .padding(.horizontal, MuesliTheme.spacing24)
                    .padding(.bottom, MuesliTheme.spacing24)
                }
            }
        }
        .sheet(isPresented: $isBridgeQRCodePresented) {
            IPhoneBridgeQRCodeSheet(
                deepLinkURL: IPhoneBridgeLinks.iOSSyncDeepLinkURL,
                installURL: IPhoneBridgeLinks.installURL
            )
        }
    }

    private var bridgeState: ICloudBridgeState {
        appState.iCloudBridgeState
    }

    private var iPhoneBridgeCard: some View {
        HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
            BridgeSyncIcon(
                systemName: bridgeIcon,
                isAnimating: bridgeSyncIconIsAnimating,
                font: .system(size: 18, weight: .semibold)
            )
                .foregroundStyle(bridgeIconColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(bridgeTitle)
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(bridgeSubtitle)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: MuesliTheme.spacing12)

            if shouldShowBridgeHandoffButton {
                Button {
                    isBridgeQRCodePresented = true
                    TelemetryDeck.signal("bridge_qr_shown", parameters: ["platform": "macos"])
                } label: {
                    Image(systemName: "qrcode")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .frame(width: 28, height: 28)
                        .background(MuesliTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)
                .help("Show iPhone setup QR")
            }

            Button {
                bridgePrimaryAction()
            } label: {
                HStack(spacing: 6) {
                    Text(bridgeButtonTitle)
                    BridgeSyncIcon(
                        systemName: bridgeButtonIcon,
                        isAnimating: bridgeButtonIconIsAnimating,
                        font: .system(size: 12, weight: .semibold)
                    )
                }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(MuesliTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            .buttonStyle(.plain)
            .disabled(bridgeActionDisabled)
            .help(bridgeButtonHelp)

            Button {
                controller.updateConfig { $0.showIOSCompanionPrompt = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .frame(width: 28, height: 28)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            .buttonStyle(.plain)
            .help("Hide iOS companion prompt")
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
        .onAppear {
            guard !bridgePromptSeen else { return }
            bridgePromptSeen = true
            TelemetryDeck.signal("bridge_prompt_seen", parameters: ["platform": "macos"])
        }
    }

    private var shouldShowBridgeHandoffButton: Bool {
        guard appState.config.iCloudSyncEnabled else { return false }
        switch bridgeState {
        case .needsICloud, .error:
            return false
        case .active:
            return appState.iCloudBridgeCompanionDeviceName == nil
        case .notConfigured, .checkingICloud, .syncing:
            return false
        }
    }

    private var bridgeSyncIconIsAnimating: Bool {
        isBridgeSyncWorking && bridgeIcon == "arrow.triangle.2.circlepath"
    }

    private var bridgeButtonIconIsAnimating: Bool {
        isBridgeSyncWorking && bridgeButtonIcon == "arrow.triangle.2.circlepath"
    }

    private var isBridgeSyncWorking: Bool {
        bridgeState == .checkingICloud || bridgeState == .syncing
    }

    private var bridgeIcon: String {
        switch bridgeState {
        case .active:
            return "checkmark.icloud"
        case .checkingICloud, .syncing:
            return "arrow.triangle.2.circlepath"
        case .needsICloud, .error:
            return "exclamationmark.icloud"
        case .notConfigured:
            return "iphone.gen3"
        }
    }

    private var bridgeIconColor: Color {
        switch bridgeState {
        case .active:
            return MuesliTheme.success
        case .needsICloud, .error:
            return MuesliTheme.transcribing
        default:
            return MuesliTheme.accent
        }
    }

    private var bridgeTitle: String {
        switch bridgeState {
        case .active:
            guard let deviceName = appState.iCloudBridgeCompanionDeviceName else {
                if let lastSyncedAt = appState.iCloudLastSyncedAt {
                    return "iCloud sync active · \(relativeSyncTime(lastSyncedAt))"
                }
                return "iCloud sync active"
            }
            if let lastSyncedAt = appState.iCloudLastSyncedAt {
                return "Synced with \(deviceName) · \(relativeSyncTime(lastSyncedAt))"
            }
            return "Synced with \(deviceName)"
        case .checkingICloud, .syncing:
            return "Setting up private iCloud sync"
        case .needsICloud:
            return "Sign in to iCloud to sync"
        case .error:
            return "iPhone sync needs attention"
        case .notConfigured:
            return "Use Muesli on iPhone"
        }
    }

    private var bridgeSubtitle: String {
        switch bridgeState {
        case .active:
            if let deviceName = appState.iCloudBridgeCompanionDeviceName {
                return "Private iCloud text sync is on with \(deviceName). Audio stays local."
            }
            return "Scan the QR code to connect your iPhone. Audio stays local."
        case .checkingICloud:
            return "Checking this Mac's iCloud account..."
        case .syncing:
            return "Creating the sync channel and pulling your latest text records."
        case .needsICloud, .error:
            return appState.iCloudBridgeMessage ?? "Open iCloud settings, then try again."
        case .notConfigured:
            return "Your Muesli history follows you through private iCloud. Audio stays local."
        }
    }

    private var bridgeButtonTitle: String {
        switch bridgeState {
        case .active:
            return "Sync"
        case .checkingICloud, .syncing:
            return "Syncing"
        case .needsICloud, .error:
            return "Try again"
        case .notConfigured:
            return "Set up private iCloud sync"
        }
    }

    private var bridgeButtonIcon: String {
        switch bridgeState {
        case .notConfigured:
            return "icloud"
        default:
            return "arrow.triangle.2.circlepath"
        }
    }

    private var bridgeActionDisabled: Bool {
        bridgeState == .checkingICloud || bridgeState == .syncing
    }

    private var bridgeButtonHelp: String {
        switch bridgeState {
        case .active:
            return "Sync text with iCloud"
        case .checkingICloud, .syncing:
            return "Sync setup is in progress"
        default:
            return "Set up private iCloud text sync"
        }
    }

    private func bridgePrimaryAction() {
        switch bridgeState {
        case .active:
            controller.performICloudSync()
        case .checkingICloud, .syncing:
            break
        default:
            controller.enableIPhoneBridgeSync()
        }
    }

    private func relativeSyncTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var emptyStateInstruction: String {
        appState.config.resolvedOnboardingUseCase.includesVoiceNotes
            ? "Click Record Voice Note to capture your first note"
            : "Hold \(appState.config.dictationHotkey.label) to start dictating"
    }

    private var voiceNoteButton: some View {
        let isRecording = appState.isVoiceNoteRecording
        return Button {
            controller.toggleVoiceNoteRecording()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text(isRecording ? "Stop Voice Note" : "Record Voice Note")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(isRecording ? MuesliTheme.recording : MuesliTheme.accent)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
        .buttonStyle(.plain)
        .disabled(appState.dictationState == .transcribing)
        .opacity(appState.dictationState == .transcribing ? 0.55 : 1)
    }

    @ViewBuilder
    private var dateFilterButton: some View {
        Menu {
            ForEach(availableFilters, id: \.self) { filter in
                Button {
                    selectedFilter = filter
                    applyFilter(filter)
                } label: {
                    HStack {
                        Text(filter.label)
                        if selectedFilter == filter {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11))
                if selectedFilter != .all {
                    Text(selectedFilter.label)
                        .font(.system(size: 11))
                }
            }
            .foregroundStyle(selectedFilter != .all ? MuesliTheme.accent : MuesliTheme.textTertiary)
            .padding(.horizontal, selectedFilter != .all ? 8 : 0)
            .padding(.vertical, 3)
            .background(selectedFilter != .all ? MuesliTheme.accent.opacity(0.12) : Color.clear)
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// Build filter options dynamically based on the date range of actual data.
    private var availableFilters: [DictationFilter] {
        var filters: [DictationFilter] = [.all]
        let calendar = Calendar.current
        let now = Date()

        // Check oldest dictation to determine which filters make sense
        let oldestDate: Date? = appState.dictationRows.last.flatMap { parseDate($0.timestamp) }
            ?? appState.dictationRows.first.flatMap { parseDate($0.timestamp) }

        guard let oldest = oldestDate else { return filters }
        let daysSinceOldest = calendar.dateComponents([.day], from: oldest, to: now).day ?? 0

        // Always show "Last 2 days" if data spans more than today
        if daysSinceOldest >= 1 { filters.append(.last2Days) }
        if daysSinceOldest >= 3 { filters.append(.lastWeek) }
        if daysSinceOldest >= 8 { filters.append(.last2Weeks) }
        if daysSinceOldest >= 15 { filters.append(.lastMonth) }
        if daysSinceOldest >= 31 { filters.append(.last3Months) }

        return filters
    }

    private func applyFilter(_ filter: DictationFilter) {
        let calendar = Calendar.current
        let now = Date()

        switch filter {
        case .all:
            controller.clearDictationFilter()
        case .last2Days:
            controller.filterDictations(from: calendar.date(byAdding: .day, value: -2, to: now), to: nil)
        case .lastWeek:
            controller.filterDictations(from: calendar.date(byAdding: .day, value: -7, to: now), to: nil)
        case .last2Weeks:
            controller.filterDictations(from: calendar.date(byAdding: .day, value: -14, to: now), to: nil)
        case .lastMonth:
            controller.filterDictations(from: calendar.date(byAdding: .month, value: -1, to: now), to: nil)
        case .last3Months:
            controller.filterDictations(from: calendar.date(byAdding: .month, value: -3, to: now), to: nil)
        }
    }

    // MARK: - Date parsing

    private static let parsers: [DateFormatterProtocol] = {
        let iso1 = ISO8601DateFormatter()
        iso1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        iso2.formatOptions = [.withInternetDateTime]
        let local1: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
            return f
        }()
        let local2: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return f
        }()
        return [iso1, iso2, local1, local2]
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "hh:mm a"
        return f
    }()

    private func parseDate(_ raw: String) -> Date? {
        for parser in Self.parsers {
            if let date = parser.date(from: raw) {
                return date
            }
        }
        return nil
    }

    private func formatTimeOnly(_ raw: String) -> String {
        guard let date = parseDate(raw) else {
            let clean = raw.replacingOccurrences(of: "T", with: " ")
            return clean.count > 5 ? String(clean.suffix(8).prefix(5)) : clean
        }
        return Self.timeFormatter.string(from: date)
    }
}

private struct BridgeSyncIcon: View {
    let systemName: String
    let isAnimating: Bool
    let font: Font
    @State private var rotationDegrees = 0.0

    var body: some View {
        Image(systemName: systemName)
            .font(font)
            .symbolRenderingMode(.hierarchical)
            .rotationEffect(.degrees(rotationDegrees))
            .onAppear {
                updateRotation(animated: false)
            }
            .onChange(of: isAnimating) { _, _ in
                updateRotation(animated: true)
            }
    }

    private func updateRotation(animated: Bool) {
        guard isAnimating else {
            if animated {
                withAnimation(.easeOut(duration: 0.15)) {
                    rotationDegrees = 0
                }
            } else {
                rotationDegrees = 0
            }
            return
        }

        rotationDegrees = 0
        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
            rotationDegrees = 360
        }
    }
}

private struct IPhoneBridgeQRCodeSheet: View {
    let deepLinkURL: URL
    let installURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var didCopySetupLink = false

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Open Muesli on iPhone")
                        .font(MuesliTheme.title3())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Scan this after installing the iPhone app. The QR only opens setup; private iCloud does the actual sync.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .frame(width: 28, height: 28)
                        .background(MuesliTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .center, spacing: MuesliTheme.spacing16) {
                QRCodeImage(payload: deepLinkURL.absoluteString)
                    .frame(width: 148, height: 148)
                    .padding(MuesliTheme.spacing8)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))

                VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    Label("Same iCloud account", systemImage: "icloud")
                    Label("Text sync only", systemImage: "text.badge.checkmark")
                    Label("Audio stays local", systemImage: "lock")
                }
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
            }

            HStack(spacing: MuesliTheme.spacing8) {
                Button("Open iPhone app page") {
                    NSWorkspace.shared.open(installURL)
                }
                .buttonStyle(.bordered)

                Button(didCopySetupLink ? "Copied!" : "Copy setup link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(deepLinkURL.absoluteString, forType: .string)
                    didCopySetupLink = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(1500))
                        didCopySetupLink = false
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(MuesliTheme.spacing20)
        .frame(width: 430)
        .background(MuesliTheme.backgroundBase)
    }
}

private struct QRCodeImage: View {
    let payload: String
    @State private var cachedImage: NSImage?

    var body: some View {
        Group {
            if let image = cachedImage {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 96, weight: .regular))
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
        }
        .accessibilityLabel("iPhone sync setup QR code")
        .onAppear {
            if cachedImage == nil {
                cachedImage = makeQRCodeImage(payload: payload)
            }
        }
    }

    private func makeQRCodeImage(payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else {
            return nil
        }

        let representation = NSCIImageRep(ciImage: outputImage)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

private protocol DateFormatterProtocol {
    func date(from string: String) -> Date?
}

extension DateFormatter: DateFormatterProtocol {}
extension ISO8601DateFormatter: DateFormatterProtocol {}
