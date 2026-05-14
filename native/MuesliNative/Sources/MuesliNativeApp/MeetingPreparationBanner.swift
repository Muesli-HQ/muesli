import SwiftUI

struct MeetingPreparationBanner: View {
    let status: String?
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 18, height: 18)
                .accessibilityLabel("Preparing meeting")

            VStack(alignment: .leading, spacing: 2) {
                Text("Preparing meeting")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(status ?? "Loading transcription, VAD, and speaker diarization...")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: MuesliTheme.spacing12)

            Button(action: onCancel) {
                Label("Cancel", systemImage: "xmark.circle")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Cancel meeting preparation")
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }
}
