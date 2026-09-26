import AppKit
import SwiftUI

struct ComputerUseQuestion: Codable, Equatable, Sendable {
    let question: String
    let options: [String]

    func validate() throws {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (2...4).contains(options.count),
              options.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }).count == options.count else {
            throw MuesliSettings.Failure.rejected("The clarification question was invalid. Nothing was changed.")
        }
    }
}

/// Owns a single suspended question. Closing the panel or stopping the command
/// cancels its continuation exactly once; no detached follow-up command is needed.
@MainActor
final class ComputerUseQuestionPresenter: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var continuation: CheckedContinuation<String, Error>?
    private var activeID: UUID?

    func ask(_ question: ComputerUseQuestion) async throws -> String {
        try question.validate()
        try Task.checkCancellation()
        cancel()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                activeID = id
                let panel = QuestionPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                    styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.title = "Muesli needs your answer"
                panel.isReleasedWhenClosed = false
                panel.hidesOnDeactivate = false
                panel.level = .floating
                panel.delegate = self
                let content = NSHostingView(rootView: ComputerUseQuestionView(question: question,
                    answer: { [weak self] answer in self?.finish(.success(answer)) },
                    cancel: { [weak self] in self?.cancel() }))
                panel.contentView = content
                panel.setContentSize(content.fittingSize)
                panel.center()
                self.panel = panel
                panel.orderFrontRegardless()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.activeID == id else { return }
                self?.cancel()
            }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }
    func windowWillClose(_ notification: Notification) { cancel() }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        activeID = nil
        panel?.delegate = nil
        panel?.close()
        panel = nil
        continuation.resume(with: result)
    }
}

private final class QuestionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct ComputerUseQuestionView: View {
    let question: ComputerUseQuestion
    let answer: (String) -> Void
    let cancel: () -> Void
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(question.question).font(.headline).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                Button { answer(option) } label: {
                    Text(option).frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }.buttonStyle(.bordered)
            }
            TextField("Or type your answer", text: $text)
                .textFieldStyle(.roundedBorder).onSubmit(submit)
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Submit", action: submit).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 460)
    }
    private func submit() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { answer(value) }
    }
}
