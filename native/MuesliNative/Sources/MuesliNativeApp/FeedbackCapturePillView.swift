import SwiftUI

struct FeedbackCapturePillView: View {
    let state: FeedbackCapturePillState
    var power: () -> Float = { -160 }
    var finish: () -> Void = {}
    var discard: () -> Void = {}
    var open: () -> Void = {}
    var repairPermission: () -> Void = {}
    var copy: (() -> Void)?
    var reduceMotionOverride: Bool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .preparing, .processing:
                ProgressView().controlSize(.small)
            case .recording(_, let dead), .discardConfirmation(_, let dead):
                Circle().fill(.red).frame(width: 7, height: 7)
                if dead {
                    Rectangle().fill(.red).frame(width: 32, height: 2).accessibilityLabel("No microphone samples")
                } else {
                    NotchWaveform(power: power, scrolling: false, reduceMotion: reduceMotionOverride ?? reduceMotion,
                                  accent: RecordingIndicatorPalette.accent(hex: "FF3B30"))
                        .frame(width: 36, height: 18).accessibilityLabel("Microphone level")
                }
            default: EmptyView()
            }
            Text(state.title).fixedSize(horizontal: false, vertical: true)
            if state.isRecording {
                Button(action: discard) { Image(systemName: "xmark") }.accessibilityLabel("Discard capture")
                Button("Finish", action: finish)
            } else {
                switch state {
                case .blocked: Button("Open Settings", action: repairPermission)
                case .readyToCopy:
                    Button("Copy") { copy?() }.disabled(copy == nil)
                    Button("Open", action: open)
                case .ready, .recovered, .copied: Button("Open", action: open)
                case .failed(_, _, let retained) where retained: Button("Open", action: open)
                default: EmptyView()
                }
            }
        }
        .font(.system(size: 12, weight: .medium)).buttonStyle(.plain)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .foregroundStyle(.white)
        .background(.black, in: Capsule())
    }
}
