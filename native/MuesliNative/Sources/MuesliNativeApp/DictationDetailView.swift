import AppKit
import SwiftUI
import MuesliCore

struct DictationDetailView: View {
    let record: DictationRecord
    let controller: MuesliController
    @Environment(\.dismiss) private var dismiss

    @State private var filteredText: String
    @State private var wordCount: Int
    @State private var isRerunning = false
    @State private var copiedRaw = false
    @State private var copiedFiltered = false

    init(record: DictationRecord, controller: MuesliController) {
        self.record = record
        self.controller = controller
        _filteredText = State(initialValue: record.rawText)
        _wordCount = State(initialValue: record.wordCount)
    }

    private var hasRawASR: Bool {
        record.asrText != nil && !(record.asrText?.isEmpty ?? true)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if hasRawASR {
                twoPanelLayout
            } else {
                singlePanelLayout
            }

            Divider()
            footer
        }
        .frame(width: 720, height: 520)
        .background(MuesliTheme.backgroundDeep)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcription Pipeline")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(formatTimestamp(record.timestamp))
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, MuesliTheme.spacing24)
        .padding(.top, MuesliTheme.spacing20)
        .padding(.bottom, MuesliTheme.spacing16)
    }

    private var twoPanelLayout: some View {
        HStack(spacing: MuesliTheme.spacing16) {
            panel(
                title: "Raw ASR",
                subtitle: "Before post-processing",
                text: record.asrText ?? "",
                isCopied: copiedRaw,
                onCopy: {
                    controller.copyToClipboard(record.asrText ?? "")
                    copiedRaw = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copiedRaw = false
                    }
                }
            )

            panel(
                title: "Filtered",
                subtitle: "After post-processing",
                text: filteredText,
                isCopied: copiedFiltered,
                onCopy: {
                    controller.copyToClipboard(filteredText)
                    copiedFiltered = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copiedFiltered = false
                    }
                }
            )
        }
        .padding(.horizontal, MuesliTheme.spacing24)
        .padding(.bottom, MuesliTheme.spacing16)
    }

    private var singlePanelLayout: some View {
        VStack(spacing: MuesliTheme.spacing8) {
            panel(
                title: "Transcript",
                subtitle: "Raw ASR was not captured for this dictation",
                text: filteredText,
                isCopied: copiedFiltered,
                onCopy: {
                    controller.copyToClipboard(filteredText)
                    copiedFiltered = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copiedFiltered = false
                    }
                }
            )
        }
        .padding(.horizontal, MuesliTheme.spacing24)
        .padding(.bottom, MuesliTheme.spacing16)
    }

    private func panel(title: String, subtitle: String, text: String, isCopied: Bool, onCopy: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(subtitle)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
                Spacer()
                Button(action: onCopy) {
                    Label(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                        .font(MuesliTheme.caption())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            ScrollView {
                Text(text.isEmpty ? "(empty)" : text)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(MuesliTheme.spacing12)
            }
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var footer: some View {
        HStack {
            if hasRawASR {
                Button {
                    Task {
                        isRerunning = true
                        let result = await controller.rerunPostProcessing(for: record.id)
                        if let result {
                            filteredText = result
                            wordCount = result.split(whereSeparator: \.isWhitespace).count
                        }
                        isRerunning = false
                    }
                } label: {
                    if isRerunning {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Re-running…")
                        }
                    } else {
                        Label("Re-run filtering", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isRerunning)
            }
            Spacer()
            Text("\(wordCount) words")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
        }
        .padding(.horizontal, MuesliTheme.spacing24)
        .padding(.vertical, MuesliTheme.spacing12)
    }

    private func formatTimestamp(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso) ?? Date()
        let display = DateFormatter()
        display.locale = Locale.current
        display.dateStyle = .medium
        display.timeStyle = .short
        return display.string(from: date)
    }
}
