#if DEBUG
import AppKit
import SwiftUI

/// Visual sandbox only: no recording, automation, or approval side effects.
/// Keeping state above the expanded panel preserves instructions when collapsed.
struct NotchInstructionPreview: View {
    let accent: Color
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mode = "Quill"
    @State private var phase = "Listening"
    @State private var expanded = true
    @State private var showContext = false
    @State private var response: String?

    init(accent: Color, mode: String = "Quill", phase: String = "Listening") {
        self.accent = accent
        _mode = State(initialValue: mode)
        _phase = State(initialValue: phase)
    }

    private var instruction: String {
        mode == "Quill" ? "Make this shorter and more conversational."
            : "Find a time for the design review tomorrow."
    }
    private var modeIcon: String { mode == "Quill" ? "pencil.tip" : "cursorarrow" }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Expanded instruction panel").font(.headline)
                    Text("Visual preview · sample content · no actions are executed")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Picker("Mode", selection: $mode) {
                    Text("Quill").tag("Quill")
                    Text("Computer use").tag("Computer use")
                }.pickerStyle(.segmented).frame(width: 240)
                Spacer()
                Picker("State", selection: $phase) {
                    ForEach(["Listening", "Working", "Needs approval", "Complete"], id: \.self) {
                        Text($0).tag($0)
                    }
                }.frame(width: 225)
            }
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(white: 0.24), Color(white: 0.12)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Button { expanded.toggle() } label: {
                            Image(systemName: modeIcon).font(.system(size: 17, weight: .medium))
                                .frame(width: 110, height: 34)
                        }.help(expanded ? "Collapse instruction" : "Expand instruction")
                            .accessibilityLabel(expanded ? "Collapse instruction" : "Expand instruction")
                        Color.black.frame(width: 180, height: 34).accessibilityHidden(true)
                        HStack(spacing: 14) {
                            stateIcon
                            Button { expanded.toggle() } label: {
                                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            }.accessibilityLabel(expanded ? "Collapse instruction" : "Expand instruction")
                        }.frame(width: 110, height: 34)
                    }
                    .background(.black)
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: expanded ? 0 : 12,
                                                      bottomTrailingRadius: expanded ? 0 : 12))
                    if expanded {
                        instructionPanel
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .foregroundStyle(.white)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .top)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: expanded)
            }
            .frame(height: 340)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("The panel stays centered beneath the camera. Collapsing it keeps the instruction.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 700)
        .tint(accent)
        .onChange(of: mode) { _, _ in response = nil; showContext = false }
        .onChange(of: phase) { _, _ in response = nil }
    }

    @ViewBuilder private var stateIcon: some View {
        if phase == "Listening" {
            HStack(spacing: 2) {
                ForEach(0..<9) { index in
                    Capsule().fill(accent)
                        .frame(width: 2, height: [5.0, 9, 14, 19, 15, 10, 16, 8, 4][index])
                }
            }.accessibilityLabel("Listening")
        } else if phase == "Working" {
            ProgressView().controlSize(.small).tint(accent).accessibilityLabel("Processing")
        } else {
            Image(systemName: phase == "Complete" ? "circle.inset.filled" : "exclamationmark.bubble")
                .foregroundStyle(accent).accessibilityLabel(phase)
        }
    }

    private var instructionPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(instruction).font(.system(size: 17, weight: .medium))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if mode == "Quill" {
                DisclosureGroup("Selected text", isExpanded: $showContext) {
                    Text("We would like to arrange a review of the updated design tomorrow, if you have time.")
                        .font(.callout).foregroundStyle(.white.opacity(0.65)).padding(.top, 8)
                }.font(.callout).tint(accent)
            } else {
                Divider().overlay(.white.opacity(0.1))
                HStack(spacing: 10) {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable().frame(width: 24, height: 24)
                    } else { Image(systemName: "calendar").foregroundStyle(accent) }
                    Text("Opening Calendar").font(.callout)
                }
            }
            if phase == "Needs approval" {
                Divider().overlay(.white.opacity(0.1))
                HStack {
                    Image(systemName: "exclamationmark.bubble").foregroundStyle(accent)
                    Text(response ?? (mode == "Quill" ? "Replace selected text?" : "Create this event?"))
                        .font(.callout)
                    Spacer()
                    Button("Cancel") { response = "Preview cancelled" }
                        .buttonStyle(.bordered)
                    Button("Allow") { response = "Preview allowed" }
                        .buttonStyle(.borderedProminent).tint(accent)
                }
                Text("Preview only — these buttons do not authorize real actions.")
                    .font(.caption2).foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(20).frame(width: 440, alignment: .leading)
        .background(Color(white: 0.055))
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18))
        .overlay {
            UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18)
                .strokeBorder(accent.opacity(0.35), lineWidth: 0.7).allowsHitTesting(false)
        }
    }
}
#endif
