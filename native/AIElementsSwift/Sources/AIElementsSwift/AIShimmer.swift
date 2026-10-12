import SwiftUI

/// A readable status label with a subtle highlight sweep. It owns no timer and
/// communicates no progress beyond the host's supplied text. Reduce Motion
/// removes the animated layer; VoiceOver reads the baseline text only once.
public struct AIShimmer: View {
    private let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(verbatim: text)
            .overlay {
                if !reduceMotion {
                    AIShimmerSweep(text: text)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct AIShimmerSweep: View {
    let text: String
    @State private var isSweeping = false

    var body: some View {
        GeometryReader { geometry in
            LinearGradient(
                colors: [.clear, .primary.opacity(0.38), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geometry.size.width * 0.65, height: geometry.size.height)
            .offset(x: isSweeping ? geometry.size.width : -geometry.size.width * 0.65)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            .mask {
                Text(verbatim: text)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            }
            .clipped()
        }
        .onAppear {
            withAnimation(.linear(duration: 1.8).delay(0.25).repeatForever(autoreverses: false)) {
                isSweeping = true
            }
        }
    }
}
