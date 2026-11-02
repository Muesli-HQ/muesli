import SwiftUI

/// Shared recording control for meetings and ambient screen history.
struct RecordingPauseButton: View {
    let isPaused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(isPaused ? "Resume" : "Pause")
                    .font(MuesliTheme.font(size: 12, weight: .semibold))
            }
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, 7)
        }
        .buttonStyle(.muesli(isPaused ? .primary : .secondary))
    }
}
