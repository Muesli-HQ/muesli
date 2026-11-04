import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Local presentation only: stable IDs survive renamed labels and new destinations.
enum SidebarOrder {
    static let preferenceKey = "dashboard.sidebar.order.v1"
    static let defaults: [DashboardTab] = [
        .timeline, .timeTurner, .dictations, .meetings, .meetingChat, .insights, .dictionary
    ]

    static func tabs(from saved: String) -> [DashboardTab] {
        var seen = Set<String>()
        let known = saved.split(separator: ",").compactMap { DashboardTab(rawValue: String($0)) }
            .filter { defaults.contains($0) }
        return (known + defaults).filter { seen.insert($0.rawValue).inserted }
    }

    static func encode(_ tabs: [DashboardTab]) -> String {
        tabs.map(\.rawValue).joined(separator: ",")
    }

    static func moving(_ tab: DashboardTab, to target: DashboardTab, in saved: String) -> String {
        var order = tabs(from: saved)
        guard let source = order.firstIndex(of: tab), let destination = order.firstIndex(of: target),
              source != destination else { return saved }
        order.remove(at: source)
        order.insert(tab, at: destination)
        return encode(order)
    }

    static func inserting(_ tab: DashboardTab, relativeTo target: DashboardTab, after: Bool, in saved: String) -> String {
        guard defaults.contains(tab), defaults.contains(target), tab != target else { return saved }
        var order = tabs(from: saved)
        order.removeAll { $0 == tab }
        guard let index = order.firstIndex(of: target) else { return saved }
        order.insert(tab, at: index + (after ? 1 : 0))
        return encode(order)
    }

}

private let sidebarTabType = UTType(exportedAs: "com.muesli.sidebar-tab", conformingTo: .data)

/// The drag gesture belongs to the label, inside Button's click recognizer.
/// Putting it around the Button lets native button tracking consume the mouse drag.
struct SidebarDragSourceModifier: ViewModifier {
    let tab: DashboardTab
    let label: String

    func body(content: Content) -> some View {
        if SidebarOrder.defaults.contains(tab) {
            content
            .onDrag {
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: sidebarTabType.identifier, visibility: .ownProcess) { completion in
                    completion(Data(tab.rawValue.utf8), nil)
                    return nil
                }
                return provider
            } preview: {
                Text(label)
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .padding(10)
                    .background(MuesliTheme.backgroundRaised, in: RoundedRectangle(cornerRadius: 8))
            }
        } else {
            content
        }
    }
}

/// Dedicated payload keeps navigation drags separate from folder and meeting drops.
struct SidebarReorderModifier: ViewModifier {
    let tab: DashboardTab
    let label: String
    @Binding var savedOrder: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var acceptsDrop = true

    private var order: [DashboardTab] { SidebarOrder.tabs(from: savedOrder) }
    private var index: Int { order.firstIndex(of: tab) ?? 0 }

    func body(content: Content) -> some View {
        content
            .modifier(SidebarDropModifier(tab: tab, savedOrder: $savedOrder, enabled: acceptsDrop))
            .contextMenu {
                Button("Move up") { move(tab, to: order[index - 1]) }
                    .disabled(index == 0)
                Button("Move down") { move(tab, to: order[index + 1]) }
                    .disabled(index == order.count - 1)
                Divider()
                Button("Reset sidebar order") { savedOrder = "" }
            }
            .accessibilityHint("Drag to reorder, or use the Move up and Move down actions.")
            .accessibilityAction(named: "Move up") {
                if index > 0 { move(tab, to: order[index - 1]) }
            }
            .accessibilityAction(named: "Move down") {
                if index + 1 < order.count { move(tab, to: order[index + 1]) }
            }
    }

    private func move(_ source: DashboardTab, to target: DashboardTab) {
        withAnimation(MuesliMotion.animation(MuesliMotion.navigation, reduceMotion: reduceMotion)) {
            savedOrder = SidebarOrder.moving(source, to: target, in: savedOrder)
        }
    }
}

struct SidebarDropModifier: ViewModifier {
    let tab: DashboardTab
    @Binding var savedOrder: String
    var enabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var insertionAfter: Bool?
    @State private var rowHeight: CGFloat = 36

    func body(content: Content) -> some View {
        if enabled {
            content
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { rowHeight = geometry.size.height }
                        .onChange(of: geometry.size.height) { _, height in rowHeight = height }
                }
            }
            .onDrop(of: [sidebarTabType], delegate: SidebarTabDropDelegate(
                rowHeight: rowHeight, insertionAfter: $insertionAfter,
                commit: { source, after in
                    withAnimation(MuesliMotion.animation(MuesliMotion.navigation, reduceMotion: reduceMotion)) {
                        savedOrder = SidebarOrder.inserting(source, relativeTo: tab, after: after, in: savedOrder)
                    }
                }
            ))
            .overlay(alignment: insertionAfter == true ? .bottom : .top) {
                if insertionAfter != nil {
                    Capsule()
                        .fill(MuesliTheme.accentText)
                        .frame(height: 3)
                        .offset(y: insertionAfter == true ? 2 : -2)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: savedOrder) { _, _ in insertionAfter = nil }
            .task(id: insertionAfter != nil) { @MainActor in
                // SwiftUI can omit dropExited as rows move, or deliver a final
                // dropUpdated after performDrop. Check physical release only
                // while a marker is visible; there is no idle polling.
                guard insertionAfter != nil else { return }
                while !Task.isCancelled {
                    if NSEvent.pressedMouseButtons & 1 == 0 {
                        insertionAfter = nil
                        return
                    }
                    do {
                        try await Task.sleep(for: .milliseconds(50))
                    } catch {
                        return
                    }
                }
            }
        } else {
            content
        }
    }
}

private struct SidebarTabDropDelegate: DropDelegate {
    let rowHeight: CGFloat
    @Binding var insertionAfter: Bool?
    let commit: (DashboardTab, Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [sidebarTabType])
    }

    func dropEntered(info: DropInfo) {
        updateMarker(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateMarker(info: info)
        return DropProposal(operation: .move)
    }

    private func updateMarker(info: DropInfo) {
        // A late destination update must not resurrect the marker after release.
        insertionAfter = NSEvent.pressedMouseButtons & 1 != 0
            ? info.location.y >= rowHeight / 2 : nil
    }

    func dropExited(info: DropInfo) { insertionAfter = nil }

    func performDrop(info: DropInfo) -> Bool {
        let after = info.location.y >= rowHeight / 2
        insertionAfter = nil
        guard let provider = info.itemProviders(for: [sidebarTabType]).first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: sidebarTabType.identifier) { data, _ in
            guard let data, let id = String(data: data, encoding: .utf8),
                  let source = DashboardTab(rawValue: id), SidebarOrder.defaults.contains(source) else { return }
            Task { @MainActor in commit(source, after) }
        }
        return true
    }
}

extension DashboardTab {
    var sidebarLabel: String {
        switch self {
        case .timeline: "Timeline"
        case .timeTurner: "Time Turner"
        case .dictations: "Dictations"
        case .meetings: "Meetings"
        case .meetingChat: "Chat"
        case .insights: "Insights"
        case .dictionary: "Dictionary"
        case .models: "Models"
        case .shortcuts: "Shortcuts"
        case .settings: "Settings"
        case .about: "About"
        }
    }

    var sidebarIcon: String {
        switch self {
        case .timeline: "clock"
        case .timeTurner: "clock.arrow.circlepath"
        case .dictations: "waveform"
        case .meetings: "person.2"
        case .meetingChat: "bubble.left.and.bubble.right"
        case .insights: "chart.bar.xaxis"
        case .dictionary: "character.book.closed"
        case .models: "cpu"
        case .shortcuts: "command"
        case .settings: "gearshape"
        case .about: "info.circle"
        }
    }
}

struct OptionalSidebarReorderModifier: ViewModifier {
    let tab: DashboardTab
    let label: String
    @Binding var savedOrder: String

    func body(content: Content) -> some View {
        if SidebarOrder.defaults.contains(tab) {
            content.modifier(SidebarReorderModifier(tab: tab, label: label, savedOrder: $savedOrder))
        } else {
            content
        }
    }
}
