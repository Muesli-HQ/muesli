import SwiftUI

struct FeatureTourTargetPreferenceKey: PreferenceKey {
    static var defaultValue: [FeatureTourTarget: CGRect] = [:]

    static func reduce(
        value: inout [FeatureTourTarget: CGRect],
        nextValue: () -> [FeatureTourTarget: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

struct FeatureTourFrameTracking {
    static func hasMeaningfulChange(
        from current: [FeatureTourTarget: CGRect],
        to updated: [FeatureTourTarget: CGRect],
        tolerance: CGFloat = 0.5
    ) -> Bool {
        guard Set(current.keys) == Set(updated.keys) else { return true }
        return updated.contains { target, rect in
            guard let existing = current[target] else { return true }
            return abs(existing.minX - rect.minX) > tolerance
                || abs(existing.minY - rect.minY) > tolerance
                || abs(existing.width - rect.width) > tolerance
                || abs(existing.height - rect.height) > tolerance
        }
    }
}

private struct FeatureTourCalloutSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0, next.height > 0 {
            value = next
        }
    }
}

private enum FeatureTourCalloutEdge {
    case above
    case below
    case leading
    case trailing
}

struct FeatureTourCalloutLayout {
    static func position(
        spotlight: CGRect,
        containerSize: CGSize,
        calloutSize: CGSize,
        target: FeatureTourTarget,
        margin: CGFloat = 20,
        gap: CGFloat = 24
    ) -> CGPoint {
        let bounds = CGRect(
            x: margin,
            y: margin,
            width: max(0, containerSize.width - margin * 2),
            height: max(0, containerSize.height - margin * 2)
        )
        let candidates = preferredEdges(for: target).map {
            center(for: $0, spotlight: spotlight, calloutSize: calloutSize, gap: gap)
        }

        if let fitting = candidates.first(where: {
            bounds.contains(frame(centeredAt: $0, size: calloutSize))
        }) {
            return fitting
        }

        let clamped = candidates.map {
            clamp($0, calloutSize: calloutSize, to: bounds)
        }
        return clamped.min { lhs, rhs in
            overlapArea(frame(centeredAt: lhs, size: calloutSize), spotlight)
                < overlapArea(frame(centeredAt: rhs, size: calloutSize), spotlight)
        } ?? CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
    }

    private static func preferredEdges(for target: FeatureTourTarget) -> [FeatureTourCalloutEdge] {
        switch target {
        case .meetingsSidebar:
            return [.trailing, .leading, .below, .above]
        case .insightsEntry, .liveCaptionsSetting:
            return [.below, .above, .trailing, .leading]
        case .dictionarySuggestions, .cloudCleanupSetting, .streamingModels, .experimentalModels:
            return [.above, .below, .trailing, .leading]
        }
    }

    private static func center(
        for edge: FeatureTourCalloutEdge,
        spotlight: CGRect,
        calloutSize: CGSize,
        gap: CGFloat
    ) -> CGPoint {
        switch edge {
        case .above:
            return CGPoint(x: spotlight.midX, y: spotlight.minY - gap - calloutSize.height / 2)
        case .below:
            return CGPoint(x: spotlight.midX, y: spotlight.maxY + gap + calloutSize.height / 2)
        case .leading:
            return CGPoint(x: spotlight.minX - gap - calloutSize.width / 2, y: spotlight.midY)
        case .trailing:
            return CGPoint(x: spotlight.maxX + gap + calloutSize.width / 2, y: spotlight.midY)
        }
    }

    private static func frame(centeredAt center: CGPoint, size: CGSize) -> CGRect {
        CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func clamp(_ center: CGPoint, calloutSize: CGSize, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: clampedCoordinate(
                center.x,
                lower: bounds.minX + calloutSize.width / 2,
                upper: bounds.maxX - calloutSize.width / 2,
                fallback: bounds.midX
            ),
            y: clampedCoordinate(
                center.y,
                lower: bounds.minY + calloutSize.height / 2,
                upper: bounds.maxY - calloutSize.height / 2,
                fallback: bounds.midY
            )
        )
    }

    private static func clampedCoordinate(
        _ value: CGFloat,
        lower: CGFloat,
        upper: CGFloat,
        fallback: CGFloat
    ) -> CGFloat {
        guard lower <= upper else { return fallback }
        return min(max(value, lower), upper)
    }

    private static func overlapArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }
}

extension View {
    @ViewBuilder
    func featureTourTarget(_ target: FeatureTourTarget?) -> some View {
        if let target {
            background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: FeatureTourTargetPreferenceKey.self,
                        value: [
                            target: proxy.frame(in: .global)
                        ]
                    )
                }
            }
        } else {
            self
        }
    }
}

struct FeatureTourOverlay: View {
    let tour: FeatureTour
    let stepIndex: Int
    let spotlightRect: CGRect
    let containerSize: CGSize
    let onBack: () -> Void
    let onNext: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var calloutSize: CGSize = .zero

    private var step: FeatureTourStep {
        tour.steps[stepIndex]
    }

    private var expandedSpotlight: CGRect {
        spotlightRect.insetBy(dx: -8, dy: -8)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())

            FeatureTourDimmingShape(spotlight: expandedSpotlight, cornerRadius: 10)
                .fill(
                    Color.black.opacity(0.72),
                    style: FillStyle(eoFill: true, antialiased: true)
                )
                .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: 10)
                .stroke(MuesliTheme.accent, lineWidth: 2)
                .frame(width: expandedSpotlight.width, height: expandedSpotlight.height)
                .position(x: expandedSpotlight.midX, y: expandedSpotlight.midY)
                .shadow(color: MuesliTheme.accent.opacity(0.55), radius: 10)
                .allowsHitTesting(false)

            callout
                .frame(width: 380)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: FeatureTourCalloutSizePreferenceKey.self,
                            value: proxy.size
                        )
                    }
                }
                .opacity(calloutSize == .zero ? 0 : 1)
                .position(calloutPosition)
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .onPreferenceChange(FeatureTourCalloutSizePreferenceKey.self) { size in
            guard abs(size.width - calloutSize.width) > 0.5
                    || abs(size.height - calloutSize.height) > 0.5 else { return }
            calloutSize = size
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: step.id)
        .accessibilityElement(children: .contain)
    }

    private var callout: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                Image(systemName: step.systemImage)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(MuesliTheme.accent)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 5) {
                    Text(step.eyebrow)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(MuesliTheme.accent)
                    Text(step.title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: MuesliTheme.spacing8)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(MuesliTheme.textSecondary)
                .help("End walkthrough")
                .accessibilityLabel("End walkthrough")
            }

            Text(step.message)
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: MuesliTheme.spacing12) {
                Text("\(stepIndex + 1) of \(tour.steps.count)")
                    .font(MuesliTheme.caption())
                    .monospacedDigit()
                    .foregroundStyle(MuesliTheme.textTertiary)

                Spacer()

                if stepIndex > 0 {
                    Button(action: onBack) {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                }

                Button(action: onNext) {
                    Label(
                        stepIndex == tour.steps.count - 1 ? "Done" : "Next",
                        systemImage: stepIndex == tour.steps.count - 1 ? "checkmark" : "chevron.right"
                    )
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(MuesliTheme.spacing20)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: 12)
    }

    private var calloutPosition: CGPoint {
        FeatureTourCalloutLayout.position(
            spotlight: expandedSpotlight,
            containerSize: containerSize,
            calloutSize: calloutSize,
            target: step.target
        )
    }
}

struct FeatureTourInvitationView: View {
    let tour: FeatureTour
    let onAccept: () -> Void
    let onSkip: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.66)
                .contentShape(Rectangle())

            VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
                HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(MuesliTheme.accent)
                        .frame(width: 26, height: 26)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("MUESLI \(tour.displayVersion)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(MuesliTheme.accent)
                        Text("Want a quick tour of what’s new?")
                            .font(.system(size: 21, weight: .bold))
                            .foregroundStyle(MuesliTheme.textPrimary)
                    }

                    Spacer(minLength: MuesliTheme.spacing8)

                    Button(action: onSkip) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .help("Skip walkthrough")
                    .accessibilityLabel("Skip walkthrough")
                }

                Text("See \(tour.steps.count) additions in the places where you’ll actually use them. You can replay this later from What’s New in Muesli.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: MuesliTheme.spacing12) {
                    Spacer()
                    Button("Skip", action: onSkip)
                        .buttonStyle(.bordered)
                    Button(action: onAccept) {
                        Label("Take the Tour", systemImage: "arrow.right")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(MuesliTheme.spacing24)
            .frame(width: 460)
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.5), radius: 28, x: 0, y: 14)
        }
    }
}

private struct FeatureTourDimmingShape: Shape {
    let spotlight: CGRect
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRoundedRect(
            in: spotlight,
            cornerSize: CGSize(width: cornerRadius, height: cornerRadius)
        )
        return path
    }
}
