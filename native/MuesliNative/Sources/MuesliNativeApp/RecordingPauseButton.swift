import SwiftUI

/// Shared recording control for meetings and ambient screen history.
struct RecordingPauseButton: View {
    let isPaused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RecordingControlLabel(
                title: isPaused ? "Resume" : "Pause",
                systemImage: isPaused ? "play.fill" : "pause.fill"
            )
        }
        .buttonStyle(.muesli(isPaused ? .primary : .secondary))
    }
}

/// Recording actions must not wrap or lose their label when the header narrows.
/// Let the surrounding adaptive layout move controls instead of compressing them.
struct RecordingControlLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(MuesliTheme.font(size: 12, weight: .semibold))
        }
        .fixedSize()
        .padding(.horizontal, MuesliTheme.spacing12)
        .padding(.vertical, 7)
    }
}
