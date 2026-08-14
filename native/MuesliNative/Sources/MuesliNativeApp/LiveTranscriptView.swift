// Purpose: Scrolling live transcript view with auto-scroll during active meetings
// Created: 2026-05-22

import AppKit
import Observation
import SwiftUI

enum LiveTranscriptCopyContent {
    static func text(transcript: String, partialYou: String, partialOthers: String) -> String {
        var sections: [String] = []
        let committed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !committed.isEmpty {
            sections.append(committed)
        }
        let others = partialOthers.trimmingCharacters(in: .whitespacesAndNewlines)
        if !others.isEmpty {
            sections.append("Others: \(others)")
        }
        let you = partialYou.trimmingCharacters(in: .whitespacesAndNewlines)
        if !you.isEmpty {
            sections.append("You: \(you)")
        }
        return sections.joined(separator: "\n")
    }
}

struct LiveTranscriptBubble: View {
    let speaker: String?
    let timestamp: String?
    let lines: [String]
    let isUser: Bool
    let isPartial: Bool
    var onOpen: (() -> Void)? = nil
    @State private var isHovered = false
    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isUser { Spacer(minLength: 40) }
            if isUser { copyButton }
            VStack(alignment: .leading, spacing: 2) {
                if let speaker {
                    Text(speaker + (timestamp.map { "  \($0)" } ?? ""))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 13))
                        .italic(isPartial)
                        .foregroundStyle(isPartial ? MuesliTheme.textSecondary : MuesliTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(bubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay {
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(
                        isPartial ? MuesliTheme.surfaceBorder : committedBorder,
                        style: StrokeStyle(lineWidth: 1, dash: isPartial ? [4, 3] : [])
                    )
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpen?() }
            if !isUser { copyButton }
            if !isUser { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .onHover { isHovered = $0 }
    }

    private var copyButton: some View {
        Button(action: copyMessage) {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(didCopy ? MuesliTheme.success : MuesliTheme.textSecondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy message")
        .opacity(isHovered ? 1 : 0)
        .allowsHitTesting(isHovered)
        .accessibilityHidden(!isHovered)
    }

    private func copyMessage() {
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            didCopy = false
        }
    }

    private var bubbleBackground: Color {
        if isPartial {
            return isUser ? MuesliTheme.accent.opacity(0.06) : MuesliTheme.surfacePrimary.opacity(0.5)
        }
        return isUser ? MuesliTheme.accent.opacity(0.15) : MuesliTheme.surfacePrimary
    }

    private var committedBorder: Color {
        isUser ? MuesliTheme.accent.opacity(0.2) : MuesliTheme.surfaceBorder
    }
}

@MainActor
@Observable
final class LiveTranscriptPresentationModel {
    var transcript = ""
    var partialYou = ""
    var partialOthers = ""
    var messages: [TranscriptChatMessage] = []

    func update(transcript: String, partialYou: String, partialOthers: String) {
        guard self.transcript != transcript ||
                self.partialYou != partialYou ||
                self.partialOthers != partialOthers else { return }

        if transcript != self.transcript {
            if transcript.hasPrefix(self.transcript) {
                let appended = String(transcript.dropFirst(self.transcript.count))
                messages.append(contentsOf: TranscriptChatMessage.messages(
                    from: appended,
                    startingAt: messages.count
                ))
            } else {
                messages = TranscriptChatMessage.messages(from: transcript)
            }
            self.transcript = transcript
        }
        self.partialYou = partialYou
        self.partialOthers = partialOthers
    }

    func reset() {
        transcript = ""
        partialYou = ""
        partialOthers = ""
        messages = []
    }
}

struct LiveTranscriptFeedView: View {
    static let bottomAnchorID = "liveTranscriptBottom"

    let messages: [TranscriptChatMessage]
    let partialYou: String
    let partialOthers: String
    var horizontalPadding: CGFloat
    var topPadding: CGFloat
    var bottomPadding: CGFloat
    var onOpen: (() -> Void)? = nil

    private var trimmedPartialYou: String {
        partialYou.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPartialOthers: String {
        partialOthers.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            if messages.isEmpty && trimmedPartialYou.isEmpty && trimmedPartialOthers.isEmpty {
                Text("Waiting for speech…")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, MuesliTheme.spacing8)
            } else {
                ForEach(messages) { message in
                    LiveTranscriptBubble(
                        speaker: message.speaker,
                        timestamp: message.timestamp,
                        lines: [message.text],
                        isUser: message.isUser,
                        isPartial: false,
                        onOpen: onOpen
                    )
                }
                if !trimmedPartialOthers.isEmpty {
                    LiveTranscriptBubble(
                        speaker: "Others",
                        timestamp: nil,
                        lines: [trimmedPartialOthers],
                        isUser: false,
                        isPartial: true,
                        onOpen: onOpen
                    )
                }
                if !trimmedPartialYou.isEmpty {
                    LiveTranscriptBubble(
                        speaker: "You",
                        timestamp: nil,
                        lines: [trimmedPartialYou],
                        isUser: true,
                        isPartial: true,
                        onOpen: onOpen
                    )
                }
                Color.clear
                    .frame(height: 1)
                    .id(Self.bottomAnchorID)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
    }
}

struct LiveTranscriptView: View {
    let transcript: String
    /// Provisional streaming tails render after committed captions and remain
    /// outside the durable transcript until their chunk is committed.
    var partialYou: String = ""
    var partialOthers: String = ""
    @State private var presentation = LiveTranscriptPresentationModel()
    @State private var didCopy = false

    private var copyText: String {
        LiveTranscriptCopyContent.text(
            transcript: transcript,
            partialYou: partialYou,
            partialOthers: partialOthers
        )
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollViewReader { proxy in
                ScrollView {
                    LiveTranscriptFeedView(
                        messages: presentation.messages,
                        partialYou: presentation.partialYou,
                        partialOthers: presentation.partialOthers,
                        horizontalPadding: MuesliTheme.spacing16,
                        topPadding: 44,
                        bottomPadding: MuesliTheme.spacing8
                    )
                    .textSelection(.enabled)
                }
                .onChange(of: transcript) { _, newTranscript in
                    presentation.update(
                        transcript: newTranscript,
                        partialYou: partialYou,
                        partialOthers: partialOthers
                    )
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(LiveTranscriptFeedView.bottomAnchorID, anchor: .bottom)
                        }
                    }
                }
                // Partials update every engine chunk; scrolling on each growth
                // would yank a user who scrolled up back to the bottom every few
                // seconds. Scroll only when a tail appears (empty → non-empty);
                // committed captions keep their existing scroll behavior.
                .onChange(of: partialYou) { old, new in
                    presentation.update(
                        transcript: transcript,
                        partialYou: new,
                        partialOthers: partialOthers
                    )
                    if old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        scrollToBottom(proxy)
                    }
                }
                .onChange(of: partialOthers) { old, new in
                    presentation.update(
                        transcript: transcript,
                        partialYou: partialYou,
                        partialOthers: new
                    )
                    if old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        scrollToBottom(proxy)
                    }
                }
                .onAppear {
                    presentation.update(
                        transcript: transcript,
                        partialYou: partialYou,
                        partialOthers: partialOthers
                    )
                    DispatchQueue.main.async {
                        proxy.scrollTo(LiveTranscriptFeedView.bottomAnchorID, anchor: .bottom)
                    }
                }
            }

            Button(action: copyTranscript) {
                HStack(spacing: 6) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                    Text(didCopy ? "Copied" : "Copy")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(didCopy ? MuesliTheme.success : MuesliTheme.textPrimary)
                .padding(.horizontal, MuesliTheme.spacing12)
                .frame(height: 30)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(copyText.isEmpty)
            .padding(.top, MuesliTheme.spacing8)
            .padding(.trailing, MuesliTheme.spacing16)
        }
    }

    private func copyTranscript() {
        guard !copyText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            didCopy = false
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(LiveTranscriptFeedView.bottomAnchorID, anchor: .bottom)
            }
        }
    }
}
