import SwiftUI
import MuesliCore

struct SidebarToggleButton: View {
    static let accessibilityIdentifier = "dashboard.sidebar.toggle"

    let isCollapsed: Bool
    let action: () -> Void

    var accessibilityTitle: String {
        isCollapsed ? "Expand sidebar" : "Collapse sidebar"
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(MuesliTheme.textSecondary)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(MuesliFloatingGlassButtonStyle(shape: .circle))
        .help(accessibilityTitle)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityIdentifier(Self.accessibilityIdentifier)
    }
}

struct SidebarView: View {
    private let sidebarIconColumnWidth: CGFloat = 20
    private let meetingsTrailingColumnWidth: CGFloat = 24
    /// Meetings header actions are full-height 36pt targets; the new-folder target also owns
    /// the 4pt trailing inset, so the icons keep the former 24pt column centers.
    private let meetingsHeaderActionWidth: CGFloat = 36
    private let meetingsHeaderTrailingInset: CGFloat = 4
    /// Matches the search field's inner padding so the row icon column sits
    /// exactly under the magnifier instead of 6pt to its right.
    private let sidebarRowHorizontalPadding: CGFloat = 10
    private let sidebarRowOuterPadding: CGFloat = 8
    /// Indent for nested Meetings section rows. The sidebar is narrow (260pt by
    /// default), so show nesting by indent, but economically.
    private let meetingsChildIndent: CGFloat = 24
    private let folderDepthIndent: CGFloat = 16

    let appState: AppState
    let controller: MuesliController
    var isCollapsed: Bool = false
    var onToggleCollapsed: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SidebarOrder.preferenceKey) private var savedSidebarOrder = ""
    @State private var meetingsExpanded = true
    @State private var meetingsHeaderPressed = false
    @State private var renamingFolderID: Int64?
    @State private var renamingFolderName = ""
    @State private var folderToDelete: MeetingFolder?
    @State private var showDeleteConfirmation = false
    @State private var draggingFolderID: Int64?
    @State private var dragOrderedFolders: [MeetingFolder]?
    @State private var collapsedFolderIDs: Set<Int64> = []
    @FocusState private var isSearchFieldFocused: Bool

    private var searchTextBinding: Binding<String> {
        Binding(
            get: { appState.searchQuery },
            set: { controller.performSearch(query: $0) }
        )
    }

    private var userName: String {
        appState.config.userName
    }

    private struct UpdateCTA {
        let label: String
        let icon: String
        let accessibilityLabel: String
        let tooltip: String
    }

    private var pendingUpdateCTA: UpdateCTA? {
        switch appState.sparkleUpdateStatus {
        case .available:
            return UpdateCTA(
                label: "Update",
                icon: "arrow.down",
                accessibilityLabel: "Update available",
                tooltip: "Open About for update instructions"
            )
        case .downloaded:
            return UpdateCTA(
                label: "Ready",
                icon: "arrow.clockwise",
                accessibilityLabel: "Update ready to install",
                tooltip: "Open About for update instructions"
            )
        case .idle, .checking, .busy, .installing, .upToDate, .disabled, .failed:
            return nil
        }
    }

    var body: some View {
        if isCollapsed {
            collapsedSidebar
        } else {
            expandedSidebar
        }
    }

    private var collapsedSidebar: some View {
        VStack(spacing: MuesliTheme.spacing8) {
            sidebarToggleButton
                .padding(.top, MuesliTheme.spacing16)
                .padding(.bottom, MuesliTheme.spacing12)

            ScrollView(.vertical) {
                VStack(spacing: MuesliTheme.spacing8) {
                    ForEach(SidebarOrder.tabs(from: savedSidebarOrder), id: \.rawValue) { tab in
                        collapsedItem(tab: tab, icon: tab.sidebarIcon, label: tab.sidebarLabel)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            Spacer(minLength: 0)
            collapsedItem(tab: .models, icon: "cpu", label: "Models")
            collapsedItem(tab: .shortcuts, icon: "command", label: "Shortcuts")
            collapsedItem(tab: .settings, icon: "gearshape", label: "Settings")
            collapsedItem(tab: .about, icon: "info.circle", label: "About")
                .padding(.bottom, MuesliTheme.spacing16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MuesliTheme.backgroundDeep)
    }

    private var sidebarToggleButton: some View {
        SidebarToggleButton(isCollapsed: isCollapsed, action: onToggleCollapsed)
    }

    private func collapsedItem(tab: DashboardTab, icon: String, label: String) -> some View {
        Button {
            withAnimation(navigationAnimation) {
                if tab == .timeline {
                    controller.showTimelineHome()
                } else if tab == .meetings {
                    // Mirror the expanded Meetings action: returning to the
                    // rail must restore the browser, not leave a document open.
                    meetingsExpanded = true
                    controller.showMeetingsHome()
                } else if tab == .meetingChat {
                    controller.showMeetingChatIndex()
                } else {
                    appState.selectedTab = tab
                }
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(appState.selectedTab == tab ? MuesliTheme.accentText : MuesliTheme.textSecondary)
                .frame(width: 40, height: 36)
                .background(Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .modifier(SidebarDragSourceModifier(tab: tab, label: label))
        }
        .buttonStyle(SidebarRowButtonStyle(isSelected: appState.selectedTab == tab))
        .modifier(OptionalSidebarReorderModifier(tab: tab, label: label, savedOrder: $savedSidebarOrder))
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(appState.selectedTab == tab ? .isSelected : [])
        // Match the expanded rows so a tour targeting the sidebar keeps its
        // spotlight when the rail is collapsed mid-tour.
        .featureTourTarget(
            tab == .timeline ? .timelineSidebar
            : tab == .meetings ? .meetingsSidebar
            : nil
        )
    }

    private var expandedSidebar: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
            sidebarHeader
            searchBar

            // The navigation block scrolls so a long Meetings folder tree cannot
            // push the header and footer out of the window, or raise the
            // window's minimum height past the screen. A ScrollView has no
            // intrinsic minimum height, unlike the plain stack it replaces.
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                        ForEach(SidebarOrder.tabs(from: savedSidebarOrder), id: \.rawValue) { tab in
                            if tab == .meetings {
                                meetingsSection
                            } else {
                                sidebarItem(tab: tab, icon: tab.sidebarIcon, label: tab.sidebarLabel,
                                            updateCTA: tab == .about ? pendingUpdateCTA : nil)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: renamingFolderID) { _, folderID in
                    // A new folder enters rename mode straight away; in a long
                    // tree its row can be below the visible area, so bring it
                    // into view. Wait a turn so the new row is laid out first.
                    guard let folderID else { return }
                    Task { @MainActor in
                        await Task.yield()
                        withAnimation(navigationAnimation) {
                            proxy.scrollTo(folderID, anchor: .center)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            modelPreparationStatus
            sidebarItem(tab: .models, icon: "cpu", label: "Models")
            sidebarItem(tab: .shortcuts, icon: "command", label: "Shortcuts")
            sidebarItem(tab: .settings, icon: "gearshape", label: "Settings")
            sidebarItem(tab: .about, icon: "info.circle", label: "About", updateCTA: pendingUpdateCTA)
            darkModeToggle
                .padding(.top, MuesliTheme.spacing12)
                .padding(.bottom, MuesliTheme.spacing16)
        }
        .frame(maxHeight: .infinity)
        .background(MuesliTheme.backgroundDeep)
        .onChange(of: appState.selectedTab) { _, tab in
            if tab == .meetings {
                meetingsExpanded = true
            }
            // Reset drag state if user navigates away during a drag
            if draggingFolderID != nil {
                draggingFolderID = nil
                dragOrderedFolders = nil
            }
        }
        .alert(
            "Delete \"\(folderToDelete?.name ?? "")\"?",
            isPresented: $showDeleteConfirmation
        ) {
            Button("Cancel", role: .cancel) {
                folderToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let folder = folderToDelete {
                    controller.deleteFolder(id: folder.id)
                    controller.showMeetingsHome(folderID: appState.selectedFolderID)
                }
                folderToDelete = nil
            }
        } message: {
            let directCount = folderToDelete.map { folder in
                appState.directMeetingCountsByFolder[folder.id] ?? 0
            } ?? 0
            if directCount > 0 {
                Text("\(directCount) meeting\(directCount == 1 ? "" : "s") in this folder will be moved to Unfiled. Subfolders will be kept.")
            } else {
                Text("This folder will be permanently removed. Subfolders will be kept.")
            }
        }
    }

    @ViewBuilder
    private var sidebarHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                HStack(spacing: MuesliTheme.spacing12) {
                    Group {
                        if appState.config.menuBarIcon == "muesli",
                           let img = MenuBarIconRenderer.make(choice: "muesli") {
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFit()
                        } else {
                            Image(systemName: appState.config.menuBarIcon)
                        }
                    }
                    .frame(width: 22, height: 22)
                    .foregroundStyle(MuesliTheme.accent)
                    Text("muesli")
                        .font(MuesliTheme.title2())
                        .foregroundStyle(MuesliTheme.textPrimary)
                }
                if !userName.isEmpty {
                    Text("Hi, \(userName)")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .padding(.leading, 34)
                }
            }
            Spacer(minLength: MuesliTheme.spacing8)
            sidebarToggleButton
        }
        .padding(.horizontal, MuesliTheme.spacing16)
        .padding(.top, MuesliTheme.pageTop)
        .padding(.bottom, MuesliTheme.spacing20)
    }

    @ViewBuilder
    private var searchBar: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(MuesliTheme.textTertiary)
                .frame(width: sidebarIconColumnWidth, alignment: .center)
            TextField("Search...", text: searchTextBinding)
                .textFieldStyle(.plain)
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textPrimary)
                .focused($isSearchFieldFocused)
            if !appState.searchQuery.isEmpty {
                Button {
                    controller.clearSearch()
                    isSearchFieldFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.muesli(.quiet, shape: .circle))
                .padding(.trailing, -6)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, sidebarRowHorizontalPadding)
        .frame(height: 32)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
        .padding(.horizontal, sidebarRowOuterPadding)
        .padding(.bottom, MuesliTheme.spacing8)
        .onChange(of: appState.focusSearchField) { _, shouldFocus in
            if shouldFocus {
                isSearchFieldFocused = true
                appState.focusSearchField = false
            }
        }
    }

    @ViewBuilder
    private var meetingsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            let isSelected = appState.selectedTab == .meetings
            // The primary button owns the row's leading padding and full height; the two
            // trailing actions are separate full-height targets. One row fill reflects
            // hover and the primary button's press.
            HStack(spacing: 0) {
                Button {
                    withAnimation(navigationAnimation) {
                        meetingsExpanded = true
                    }
                    controller.showMeetingsHome()
                } label: {
                    HStack(spacing: MuesliTheme.spacing12) {
                        Image(systemName: "person.wave.2")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(isSelected ? MuesliTheme.accentText : MuesliTheme.textSecondary)
                            .frame(width: sidebarIconColumnWidth)
                        Text("Meetings")
                            .font(MuesliTheme.font(size: 14, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? MuesliTheme.textPrimary : MuesliTheme.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, sidebarRowHorizontalPadding)
                    .padding(.vertical, MuesliTheme.spacing8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .modifier(SidebarDragSourceModifier(tab: .meetings, label: "Meetings"))
                }
                .buttonStyle(SidebarHeaderButtonStyle(isPressed: $meetingsHeaderPressed))
                .modifier(SidebarReorderModifier(tab: .meetings, label: "Meetings", savedOrder: $savedSidebarOrder, acceptsDrop: false))
                .accessibilityAddTraits(isSelected ? .isSelected : [])

                Button {
                    withAnimation(navigationAnimation) {
                        meetingsExpanded.toggle()
                    }
                } label: {
                    Image(systemName: meetingsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? MuesliTheme.textSecondary : MuesliTheme.textTertiary)
                        .frame(width: meetingsHeaderActionWidth)
                        .frame(maxHeight: .infinity)
                }
                .buttonStyle(SidebarRowButtonStyle())
                .help(meetingsExpanded ? "Collapse meeting folders" : "Expand meeting folders")
                .accessibilityLabel(meetingsExpanded ? "Collapse meeting folders" : "Expand meeting folders")

                Button(action: createNewFolder) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isSelected ? MuesliTheme.textSecondary : MuesliTheme.textTertiary)
                        .frame(width: meetingsHeaderActionWidth)
                        // The trailing inset belongs to this target rather than a dead margin;
                        // it keeps the icon centers over the folder-count column below.
                        .padding(.trailing, meetingsHeaderTrailingInset)
                        .frame(maxHeight: .infinity)
                }
                .buttonStyle(SidebarRowButtonStyle())
                .help("New Meeting Folder")
                .accessibilityLabel("New meeting folder")
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(SidebarRowFeedback(isSelected: isSelected, isPressed: meetingsHeaderPressed))
            .padding(.horizontal, sidebarRowOuterPadding)
            .featureTourTarget(.meetingsSidebar)

            if meetingsExpanded {
                let folderTree = folderTreePresentation
                // Section children are indented as a group: previously they had zero
                // indent and nesting only read via the smaller icon size.
                VStack(alignment: .leading, spacing: 2) {
                    // No drag or context menu here, so this row can be a real button with press feedback.
                    allMeetingsRow(isSelected: appState.selectedTab == .meetings && appState.selectedFolderID == nil)

                    ForEach(folderTree.visibleFolders) { folder in
                        let depth = folderTree.depth(of: folder)
                        let hasChildren = folderTree.hasChildren(folder.id)
                        let isCollapsed = collapsedFolderIDs.contains(folder.id)
                        if renamingFolderID == folder.id {
                            folderRenameField(folder: folder)
                                .padding(.leading, CGFloat(depth) * folderDepthIndent)
                                .id(folder.id)
                        } else {
                            meetingFilterRow(
                                icon: "folder",
                                label: folder.name,
                                count: appState.meetingCountsByFolder[folder.id] ?? 0,
                                isSelected: appState.selectedTab == .meetings && appState.selectedFolderID == folder.id,
                                disclosureIcon: hasChildren ? (isCollapsed ? "chevron.right" : "chevron.down") : nil,
                                disclosureAction: hasChildren ? { toggleFolderCollapse(folder.id) } : nil
                            ) {
                                controller.showMeetingsHome(folderID: folder.id)
                            }
                            .padding(.leading, CGFloat(depth) * folderDepthIndent)
                            .opacity(draggingFolderID == folder.id ? 0.1 : 1)
                            .onDrag {
                                draggingFolderID = folder.id
                                dragOrderedFolders = appState.folders
                                return NSItemProvider(object: "\(folder.id)" as NSString)
                            }
                            .onDrop(of: [.text], delegate: FolderDropDelegate(
                                folderID: folder.id,
                                dragOrderedFolders: $dragOrderedFolders,
                                draggingFolderID: $draggingFolderID,
                                commitOrder: { ids in controller.reorderFolders(ids: ids) }
                            ))
                            .contextMenu {
                                Button("New Subfolder") {
                                    createNewSubfolder(parentID: folder.id)
                                }
                                Button("Rename") {
                                    renamingFolderID = folder.id
                                    renamingFolderName = folder.name
                                }
                                if folder.parentID != nil {
                                    Button("Move to Top Level") {
                                        controller.moveFolder(id: folder.id, toParent: nil)
                                    }
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    folderToDelete = folder
                                    showDeleteConfirmation = true
                                }
                            }
                        }
                    }
                }
                .padding(.leading, meetingsChildIndent)
                .padding(.horizontal, sidebarRowOuterPadding)
            }
        }
        .modifier(SidebarDropModifier(tab: .meetings, savedOrder: $savedSidebarOrder))
    }

    @ViewBuilder
    private var modelPreparationStatus: some View {
        if let title = appState.modelPreparationTitle {
            HStack(spacing: MuesliTheme.spacing8) {
                Group {
                    if appState.modelPreparationIsComplete {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(MuesliTheme.success)
                    } else if appState.isModelPreparingAfterDownload || appState.modelPreparationProgress == nil {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                    } else {
                        ProgressView(value: appState.modelPreparationProgress ?? 0, total: 1)
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                    }
                }
                .frame(width: sidebarIconColumnWidth, height: sidebarIconColumnWidth)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(MuesliTheme.font(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .lineLimit(1)
                    if let detail = appState.modelPreparationDetail, !detail.isEmpty {
                        Text(detail)
                            .font(MuesliTheme.font(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, sidebarRowHorizontalPadding)
            .padding(.vertical, MuesliTheme.spacing8)
            .background(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .fill(MuesliTheme.backgroundRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
            .padding(.horizontal, sidebarRowOuterPadding)
            .padding(.bottom, MuesliTheme.spacing4)
        }
    }

    @ViewBuilder
    private func sidebarItem(tab: DashboardTab, icon: String, label: String, updateCTA: UpdateCTA? = nil) -> some View {
        let isSelected = appState.selectedTab == tab
        Button {
            withAnimation(navigationAnimation) {
                if tab == .timeline {
                    controller.showTimelineHome()
                } else if tab == .meetingChat {
                    controller.showMeetingChatIndex()
                } else {
                    appState.selectedTab = tab
                }
            }
        } label: {
            HStack(spacing: MuesliTheme.spacing12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? MuesliTheme.accentText : MuesliTheme.textSecondary)
                    .frame(width: sidebarIconColumnWidth, height: sidebarIconColumnWidth, alignment: .center)
                Text(label)
                    .font(MuesliTheme.font(size: 14, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? MuesliTheme.textPrimary : MuesliTheme.textSecondary)
                Spacer()
                if let updateCTA {
                    HStack(spacing: 4) {
                        Image(systemName: updateCTA.icon)
                            .font(.system(size: 9, weight: .bold))
                        Text(updateCTA.label)
                            .font(MuesliTheme.font(size: 11, weight: .bold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(MuesliTheme.onAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(MuesliTheme.accent)
                    .clipShape(Capsule())
                    .shadow(color: MuesliTheme.accent.opacity(0.35), radius: 8, x: 0, y: 2)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(updateCTA.accessibilityLabel)
                    .help(updateCTA.tooltip)
                }
            }
            .padding(.horizontal, sidebarRowHorizontalPadding)
            .padding(.vertical, MuesliTheme.spacing8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .modifier(SidebarDragSourceModifier(tab: tab, label: label))
        }
        .buttonStyle(SidebarRowButtonStyle(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .padding(.horizontal, sidebarRowOuterPadding)
        .featureTourTarget(tab == .timeline ? .timelineSidebar : nil)
        .modifier(OptionalSidebarReorderModifier(tab: tab, label: label, savedOrder: $savedSidebarOrder))
    }

    private var navigationAnimation: Animation? {
        MuesliMotion.animation(MuesliMotion.navigation, reduceMotion: reduceMotion)
    }

    @ViewBuilder
    private var darkModeToggle: some View {
        MuesliSettingControl(controller: controller, id: "appearance", compactAppearance: true,
            allowedChoiceIDs: Set(AppAppearanceMode.quickChoices.map(\.rawValue)))
            .environment(\.muesliSettingDefinitions, [controller.appearanceDefinition()])
            .padding(.horizontal, sidebarRowOuterPadding)
            .padding(.leading, sidebarRowHorizontalPadding)
            .padding(.bottom, MuesliTheme.spacing4)
    }

    private func meetingFilterRowContent(icon: String, label: String, count: Int, isSelected: Bool) -> some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isSelected ? MuesliTheme.accentText : MuesliTheme.textTertiary)
                .frame(width: sidebarIconColumnWidth)
            Text(label)
                .font(MuesliTheme.callout())
                .foregroundStyle(isSelected ? MuesliTheme.textPrimary : MuesliTheme.textSecondary)
                .lineLimit(1)
            Spacer()
            Text(formattedCount(count))
                .font(MuesliTheme.caption())
                .monospacedDigit()
                .foregroundStyle(MuesliTheme.textTertiary)
                .frame(minWidth: meetingsTrailingColumnWidth, alignment: .center)
        }
        .padding(.horizontal, sidebarRowHorizontalPadding)
        .padding(.vertical, 6)
    }

    private func allMeetingsRow(isSelected: Bool) -> some View {
        Button {
            controller.showMeetingsHome()
        } label: {
            meetingFilterRowContent(icon: "tray.2", label: "All Meetings", count: appState.totalMeetingCount, isSelected: isSelected)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Folder rows stay gestures so drag/drop and context menus keep working. They show
    /// hover and selection fills; a mouse-down fill would need a zero-distance gesture that
    /// competes with the drag source, so it is intentionally omitted.
    @ViewBuilder
    private func meetingFilterRow(
        icon: String,
        label: String,
        count: Int,
        isSelected: Bool,
        disclosureIcon: String? = nil,
        disclosureAction: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) -> some View {
        meetingFilterRowContent(icon: icon, label: label, count: count, isSelected: isSelected)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(SidebarRowFeedback(isSelected: isSelected))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            // The row stays a gesture so folder drag/drop and context menus keep working; it is
            // one keyboard/VoiceOver element. The disclosure overlay below remains its own Button.
            .accessibilityElement(children: .combine)
            .muesliRowActivation(isSelected: isSelected, action: action)
            .overlay(alignment: .leading) {
                if let disclosureIcon, let disclosureAction {
                    // Fills the indent left of the row; it never overlaps the row's own target.
                    Button(action: disclosureAction) {
                        Image(systemName: disclosureIcon)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .frame(width: 22, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SidebarRowButtonStyle())
                    .offset(x: -22)
                    .help(disclosureIcon == "chevron.right" ? "Show subfolders" : "Hide subfolders")
                    .accessibilityLabel(disclosureIcon == "chevron.right" ? "Show subfolders of \(label)" : "Hide subfolders of \(label)")
                }
            }
    }

    @ViewBuilder
    private func folderRenameField(folder: MeetingFolder) -> some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MuesliTheme.accentText)
                .frame(width: sidebarIconColumnWidth)
            TextField("Folder name", text: $renamingFolderName)
                .font(MuesliTheme.callout())
                .textFieldStyle(.plain)
                .onSubmit {
                    let trimmed = renamingFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        controller.renameFolder(id: folder.id, name: trimmed)
                    }
                    renamingFolderID = nil
                }
        }
        .padding(.horizontal, sidebarRowHorizontalPadding)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .fill(MuesliTheme.surfaceSelected.opacity(0.6))
        )
    }

    private func formattedCount(_ count: Int) -> String {
        if count < 1000 { return "\(count)" }
        if count < 10000 {
            let k = Double(count) / 1000.0
            return String(format: "%.1fk", Double(Int(k * 10)) / 10.0)
        }
        return "\(count / 1000)k"
    }

    private var folderTreePresentation: FolderTreePresentation {
        FolderTreePresentation(
            folders: dragOrderedFolders ?? appState.folders,
            collapsedFolderIDs: collapsedFolderIDs
        )
    }

    private func toggleFolderCollapse(_ folderID: Int64) {
        withAnimation(MuesliMotion.animation(.easeInOut(duration: 0.12), reduceMotion: reduceMotion)) {
            if collapsedFolderIDs.contains(folderID) {
                collapsedFolderIDs.remove(folderID)
            } else {
                collapsedFolderIDs.insert(folderID)
            }
        }
    }

    private func createNewFolder() {
        if let id = controller.createFolder(name: "New Folder") {
            withAnimation(navigationAnimation) {
                meetingsExpanded = true
            }
            renamingFolderID = id
            renamingFolderName = "New Folder"
            controller.showMeetingsHome(folderID: id)
        }
    }

    private func createNewSubfolder(parentID: Int64) {
        if let id = controller.createSubfolder(name: "New Folder", parentID: parentID) {
            withAnimation(navigationAnimation) {
                meetingsExpanded = true
                collapsedFolderIDs.remove(parentID)
            }
            renamingFolderID = id
            renamingFolderName = "New Folder"
            controller.showMeetingsHome(folderID: id)
        }
    }
}

private struct FolderTreePresentation {
    let visibleFolders: [MeetingFolder]
    let depthByID: [Int64: Int]
    let childrenByParent: [Int64: [Int64]]

    init(folders: [MeetingFolder], collapsedFolderIDs: Set<Int64>) {
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        var childrenByParent: [Int64: [Int64]] = [:]
        for folder in folders {
            if let parentID = folder.parentID {
                childrenByParent[parentID, default: []].append(folder.id)
            }
        }

        var depthCache: [Int64: Int] = [:]
        func depth(for folder: MeetingFolder, visited: Set<Int64> = []) -> Int {
            if let cached = depthCache[folder.id] { return cached }
            guard let parentID = folder.parentID,
                  let parent = byID[parentID],
                  !visited.contains(folder.id) else {
                depthCache[folder.id] = 0
                return 0
            }
            var nextVisited = visited
            nextVisited.insert(folder.id)
            let value = 1 + depth(for: parent, visited: nextVisited)
            depthCache[folder.id] = value
            return value
        }

        var hiddenCache: [Int64: Bool] = [:]
        func isHidden(_ folder: MeetingFolder, visited: Set<Int64> = []) -> Bool {
            if let cached = hiddenCache[folder.id] { return cached }
            guard let parentID = folder.parentID,
                  let parent = byID[parentID],
                  !visited.contains(folder.id) else {
                hiddenCache[folder.id] = false
                return false
            }
            if collapsedFolderIDs.contains(parentID) {
                hiddenCache[folder.id] = true
                return true
            }
            var nextVisited = visited
            nextVisited.insert(folder.id)
            let hidden = isHidden(parent, visited: nextVisited)
            hiddenCache[folder.id] = hidden
            return hidden
        }

        var computedDepths: [Int64: Int] = [:]
        for folder in folders {
            computedDepths[folder.id] = depth(for: folder)
        }

        self.visibleFolders = folders.filter { !isHidden($0) }
        self.depthByID = computedDepths
        self.childrenByParent = childrenByParent
    }

    func depth(of folder: MeetingFolder) -> Int {
        depthByID[folder.id] ?? 0
    }

    func hasChildren(_ folderID: Int64) -> Bool {
        !(childrenByParent[folderID] ?? []).isEmpty
    }
}

private struct FolderDropDelegate: DropDelegate {
    let folderID: Int64
    @Binding var dragOrderedFolders: [MeetingFolder]?
    @Binding var draggingFolderID: Int64?
    let commitOrder: ([Int64]) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragID = draggingFolderID, dragID != folderID,
              var folders = dragOrderedFolders else { return }
        guard canReorder(dragID: dragID, targetID: folderID, folders: folders),
              let fromIndex = folders.firstIndex(where: { $0.id == dragID }),
              let toIndex = folders.firstIndex(where: { $0.id == folderID }) else { return }

        let draggedSubtree = subtreeIDs(rootedAt: dragID, folders: folders)
        let movedFolders = folders.filter { draggedSubtree.contains($0.id) }
        folders.removeAll { draggedSubtree.contains($0.id) }
        guard let adjustedTargetIndex = folders.firstIndex(where: { $0.id == folderID }) else { return }
        let insertionIndex: Int
        if toIndex > fromIndex {
            let targetSubtree = subtreeIDs(rootedAt: folderID, folders: folders)
            let lastTargetIndex = folders.indices.last { targetSubtree.contains(folders[$0].id) } ?? adjustedTargetIndex
            insertionIndex = lastTargetIndex + 1
        } else {
            insertionIndex = adjustedTargetIndex
        }

        MuesliMotion.perform {
            folders.insert(contentsOf: movedFolders, at: insertionIndex)
            dragOrderedFolders = folders
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        if let folders = dragOrderedFolders {
            commitOrder(folders.map(\.id))
        }
        draggingFolderID = nil
        dragOrderedFolders = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let dragID = draggingFolderID,
              let folders = dragOrderedFolders,
              canReorder(dragID: dragID, targetID: folderID, folders: folders) else {
            return nil
        }
        return DropProposal(operation: .move)
    }

    private func canReorder(dragID: Int64, targetID: Int64, folders: [MeetingFolder]) -> Bool {
        guard dragID != targetID,
              let dragged = folders.first(where: { $0.id == dragID }),
              let target = folders.first(where: { $0.id == targetID }) else {
            return false
        }
        return dragged.parentID == target.parentID
    }

    private func subtreeIDs(rootedAt rootID: Int64, folders: [MeetingFolder]) -> Set<Int64> {
        var childrenByParent: [Int64: [Int64]] = [:]
        for folder in folders {
            if let parentID = folder.parentID {
                childrenByParent[parentID, default: []].append(folder.id)
            }
        }

        var result: Set<Int64> = []
        func visit(_ id: Int64) {
            guard result.insert(id).inserted else { return }
            for childID in childrenByParent[id] ?? [] {
                visit(childID)
            }
        }
        visit(rootID)
        return result
    }
}


/// Navigation uses fills for selection and pointer feedback. Only keyboard focus gets a ring.
private struct SidebarRowButtonStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(SidebarRowFeedback(isSelected: isSelected, isPressed: configuration.isPressed))
    }
}

/// For a row's primary button when the row also hosts sibling actions: the row draws one
/// shared fill (`SidebarRowFeedback`), so this style only reports the press and focus.
private struct SidebarHeaderButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        SidebarHeaderButtonBody(configuration: configuration, isPressed: $isPressed)
    }
}

private struct SidebarHeaderButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Binding var isPressed: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.accentText, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: configuration.isPressed) { _, pressed in isPressed = pressed }
    }
}

/// Flat by design: navigation rows acknowledge a press with an immediate fill, not a scale.
private struct SidebarRowFeedback: ViewModifier {
    var isSelected: Bool
    var isPressed = false
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .fill(isSelected ? MuesliTheme.surfaceSelected :
                          (isEnabled && (isHovered || isPressed) ? MuesliTheme.backgroundHover : .clear))
                    .overlay {
                        if isEnabled && isPressed {
                            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                                .fill(MuesliTheme.textPrimary.opacity(0.04))
                        }
                    }
                    .allowsHitTesting(false)
                    .animation(MuesliMotion.animation(MuesliMotion.feedback, reduceMotion: reduceMotion), value: isHovered)
            }
            .overlay {
                if isFocused && isEnabled {
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.accentText, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}
