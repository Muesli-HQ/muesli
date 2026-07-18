import SwiftUI

/// Brand-neutral segmented navigation with a rounded moving selection.
/// It uses the existing Muesli palette so it can replace native segmented
/// controls without changing the product's visual language.
struct MuesliSegmentedTabs<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    @Namespace private var animation

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
                        selection = option
                    }
                } label: {
                    Text(title(option))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selection == option ? MuesliTheme.textPrimary : MuesliTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background {
                            if selection == option {
                                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                                    .fill(MuesliTheme.backgroundBase)
                                    .matchedGeometryEffect(id: "selection", in: animation)
                                    .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(MuesliTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .accessibilityElement(children: .contain)
    }
}
