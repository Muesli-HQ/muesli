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

/// Answer state belongs to the command, so switching/collapsing surfaces cannot
/// discard a partially typed answer or leave an orphaned continuation.
@MainActor
final class ComputerUseQuestionSession: ObservableObject {
    let id = UUID()
    let question: ComputerUseQuestion
    @Published var text = ""
    private var complete: ((Result<String, Error>) -> Void)?

    init(question: ComputerUseQuestion, complete: @escaping (Result<String, Error>) -> Void) {
        self.question = question
        self.complete = complete
    }

    func answer(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        finish(.success(value))
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<String, Error>) {
        let callback = complete
        complete = nil
        callback?(result)
    }
}

/// Coordinates the suspended tool call; the existing indicator owns all windows.
@MainActor
final class ComputerUseQuestionPresenter {
    private var session: ComputerUseQuestionSession?

    func ask(_ question: ComputerUseQuestion,
             present: (ComputerUseQuestionSession) -> Void,
             dismiss: @escaping () -> Void) async throws -> String {
        try question.validate()
        try Task.checkCancellation()
        cancel()
        let id = UUID()
        activeID = id
        defer { if activeID == id { activeID = nil; session = nil } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = ComputerUseQuestionSession(question: question) { result in
                    dismiss()
                    continuation.resume(with: result)
                }
                self.session = session
                present(session)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.activeID == id else { return }
                self?.cancel()
            }
        }
    }
    private var activeID: UUID?
    func cancel() { session?.cancel() }
}

enum ComputerUseQuestionLayout {
    static func size(in available: CGRect) -> CGSize {
        CGSize(width: min(440, available.width), height: min(360, available.height))
    }
    static func floatingFrame(anchor: CGRect, in available: CGRect) -> CGRect {
        let size = size(in: available)
        return CGRect(x: min(max(anchor.midX - size.width / 2, available.minX), available.maxX - size.width),
                      y: min(max(anchor.midY - size.height / 2, available.minY), available.maxY - size.height),
                      width: size.width, height: size.height)
    }
}

struct ComputerUseQuestionView: View {
    @ObservedObject var session: ComputerUseQuestionSession
    var notch = false
    var onCollapse: (() -> Void)? = nil
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Your answer", systemImage: "questionmark.bubble")
                    .font(.caption).foregroundStyle(.white.opacity(0.65))
                Spacer()
                if let onCollapse {
                    Button(action: onCollapse) { Image(systemName: "chevron.up") }
                        .accessibilityLabel("Collapse question")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(session.question.question).font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(Array(session.question.options.enumerated()), id: \.offset) { _, option in
                        Button { session.answer(option) } label: {
                            Text(option).frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }.buttonStyle(.bordered)
                    }
                }
            }
            TextField("Or type your answer", text: $session.text)
                .textFieldStyle(.roundedBorder).onSubmit { session.answer(session.text) }
            HStack {
                Button("Cancel") { session.cancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Submit") { session.answer(session.text) }
                    .disabled(session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.055))
        .clipShape(shape)
        .overlay { shape.strokeBorder(accent.opacity(0.5), lineWidth: 0.75).allowsHitTesting(false) }
        .foregroundStyle(.white).tint(accent).preferredColorScheme(.dark)
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: notch ? 0 : 22, bottomLeadingRadius: 22,
                               bottomTrailingRadius: 22, topTrailingRadius: notch ? 0 : 22)
    }
}
