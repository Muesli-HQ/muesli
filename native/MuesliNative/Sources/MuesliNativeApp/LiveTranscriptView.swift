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
                        .font(MuesliTheme.font(size: 10, weight: .medium))
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(MuesliTheme.font(size: 13))
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
    var newestFirst = false

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
                if newestFirst { partials }
                ForEach(newestFirst ? Array(messages.reversed()) : messages) { message in
                    LiveTranscriptBubble(
                        speaker: message.speaker,
                        timestamp: message.timestamp,
                        lines: [message.text],
                        isUser: message.isUser,
                        isPartial: false,
                        onOpen: onOpen
                    )
                }
                if !newestFirst { partials }
                Color.clear
                    .frame(height: 1)
                    .id(Self.bottomAnchorID)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
    }
    @ViewBuilder
    private var partials: some View {
        if !trimmedPartialOthers.isEmpty {
            LiveTranscriptBubble(speaker: "Others", timestamp: nil,
                lines: [trimmedPartialOthers], isUser: false, isPartial: true, onOpen: onOpen)
        }
        if !trimmedPartialYou.isEmpty {
            LiveTranscriptBubble(speaker: "You", timestamp: nil,
                lines: [trimmedPartialYou], isUser: true, isPartial: true, onOpen: onOpen)
        }
    }

}

struct LiveTranscriptView: View {
    let transcript: String
    /// Provisional streaming tails render above committed captions and remain
    /// outside the durable transcript until their chunk is committed.
    var partialYou: String = ""
    var partialOthers: String = ""
    @State private var presentation = LiveTranscriptPresentationModel()
    @State private var didCopy = false
    @State private var follow = LiveTranscriptFollowState()
    private let topID = "liveTranscriptTop"

    private var input: LiveTranscriptInput {
        .init(transcript: transcript, partialYou: partialYou, partialOthers: partialOthers)
    }

    private func refreshPresentation() {
        presentation.update(transcript: transcript, partialYou: partialYou, partialOthers: partialOthers)
    }

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
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 1).id(topID)
                        LiveTranscriptFeedView(
                            messages: presentation.messages,
                            partialYou: presentation.partialYou,
                            partialOthers: presentation.partialOthers,
                            horizontalPadding: MuesliTheme.spacing16,
                            topPadding: 44,
                            bottomPadding: MuesliTheme.spacing8,
                            newestFirst: true
                        )
                    }
                    .background {
                        LiveTranscriptScrollObserver { top in
                            if follow.updateTop(top) { refreshPresentation() }
                        }
                    }
                    .textSelection(.enabled)
                }
                .onChange(of: input) { _, _ in
                    if follow.receiveUpdate() { refreshPresentation() }
                }
                .onAppear {
                    follow.showLatest()
                    refreshPresentation()
                    proxy.scrollTo(topID, anchor: .top)
                }
                .overlay(alignment: .top) {
                    if follow.hasPendingUpdates {
                        Button {
                            follow.showLatest()
                            refreshPresentation()
                            proxy.scrollTo(topID, anchor: .top)
                        } label: {
                            Label("New messages", systemImage: "arrow.up")
                                .font(MuesliTheme.callout())
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, MuesliTheme.spacing8)
                    }
                }
            }

            Button(action: copyTranscript) {
                HStack(spacing: 6) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                    Text(didCopy ? "Copied" : "Copy")
                        .font(MuesliTheme.font(size: 12, weight: .semibold))
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
}

private struct LiveTranscriptInput: Equatable {
    let transcript: String
    let partialYou: String
    let partialOthers: String
}

/// Observe the actual clip view: SwiftUI geometry preferences on macOS do not
/// reliably update when the native scroll view moves its content.
private struct LiveTranscriptScrollObserver: NSViewRepresentable {
    var onTopChanged: (CGFloat) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ view: ObserverView, context: Context) {
        view.onTopChanged = onTopChanged
        view.attach()
    }

    final class ObserverView: NSView {
        var onTopChanged: ((CGFloat) -> Void)?
        private weak var clip: NSClipView?
        private var observation: NSObjectProtocol?

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attach() }

        func attach() {
            let next = window == nil ? nil : enclosingScrollView?.contentView
            guard next !== clip else { return }
            if let observation { NotificationCenter.default.removeObserver(observation) }
            observation = nil
            clip = next
            guard let next else { return }
            next.postsBoundsChangedNotifications = true
            observation = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: next, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        private func report() {
            // Deliver outside SwiftUI layout/update callbacks.
            DispatchQueue.main.async { [weak self] in
                guard let self, let clip = self.clip else { return }
                self.onTopChanged?(-clip.bounds.minY)
            }
        }

        deinit {
            if let observation { NotificationCenter.default.removeObserver(observation) }
        }
    }
}

/// Hold the visible snapshot while reading history. Prepending captions or
/// growing partials cannot shift that snapshot; pending updates appear on return.
struct LiveTranscriptFollowState {
    private(set) var isFollowing = true
    private(set) var hasPendingUpdates = false

    mutating func updateTop(_ minY: CGFloat) -> Bool {
        isFollowing = minY >= -24
        guard isFollowing, hasPendingUpdates else { return false }
        hasPendingUpdates = false
        return true
    }

    mutating func receiveUpdate() -> Bool {
        if !isFollowing { hasPendingUpdates = true }
        return isFollowing
    }

    mutating func showLatest() {
        isFollowing = true
        hasPendingUpdates = false
    }
}
