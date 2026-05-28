import AppKit
import SwiftUI
import MuesliCore

struct DictionaryView: View {
    let appState: AppState
    let controller: MuesliController

    @State private var isAdding = false
    @State private var newWord = ""
    @State private var newReplacement = ""
    @State private var newThreshold = 0.85
    @State private var showBulkImport = false
    @State private var bulkImportText = ""
    @State private var importMessage: String?
    @State private var importError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
                header
                wordList
            }
            .padding(MuesliTheme.spacing32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(MuesliTheme.backgroundBase)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack {
                Text("Dictionary")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Spacer()
                Button {
                    showBulkImport.toggle()
                    importMessage = nil
                    importError = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "text.badge.plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("Paste terms")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .padding(.horizontal, MuesliTheme.spacing12)
                    .padding(.vertical, MuesliTheme.spacing8)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                            .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Button {
                    importVocabularyFile()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 11, weight: .bold))
                        Text("Import file")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .padding(.horizontal, MuesliTheme.spacing12)
                    .padding(.vertical, MuesliTheme.spacing8)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                            .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Button {
                    isAdding = true
                    newWord = ""
                    newReplacement = ""
                    newThreshold = 0.85
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("Add new")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .padding(.horizontal, MuesliTheme.spacing12)
                    .padding(.vertical, MuesliTheme.spacing8)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                            .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            Text("Add custom words for names, brands, and domain terms, and tune how aggressively each entry should fuzzy-match transcription errors.")
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textSecondary)
            if let importMessage {
                Text(importMessage)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.success)
            } else if let importError {
                Text(importError)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.recording)
            }
        }
    }

    private var wordList: some View {
        VStack(spacing: 0) {
            if showBulkImport {
                bulkImportPanel
                Divider().background(MuesliTheme.surfaceBorder)
            }

            if isAdding {
                addWordRow
                Divider().background(MuesliTheme.surfaceBorder)
            }

            if appState.config.customWords.isEmpty && !isAdding {
                emptyState
            } else {
                ForEach(appState.config.customWords) { word in
                    DictionaryWordEditorRow(word: word, controller: controller)
                    Divider().background(MuesliTheme.surfaceBorder)
                }
            }
        }
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private var bulkImportPanel: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            Text("Paste one term per line, or use CSV/TSV columns: word, replacement, threshold.")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)

            TextEditor(text: $bulkImportText)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(MuesliTheme.textPrimary)
                .scrollContentBackground(.hidden)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                )
                .frame(height: 140)

            HStack {
                Text("Examples: `Skriber`, `Nabla -> Nabla`, `Kvex,Caivex,0.78`")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                Spacer()
                Button("Cancel") {
                    showBulkImport = false
                    bulkImportText = ""
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(MuesliTheme.textTertiary)

                Button("Import") {
                    importVocabularyText(bulkImportText)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MuesliTheme.accent)
                .disabled(bulkImportText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(MuesliTheme.spacing16)
    }

    private var emptyState: some View {
        VStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 28))
                .foregroundStyle(MuesliTheme.textTertiary)
            Text("No custom words yet")
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textSecondary)
            Text("Add words that transcription frequently gets wrong")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(MuesliTheme.spacing32)
    }

    private var addWordRow: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(spacing: MuesliTheme.spacing12) {
                TextField("Word", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                TextField("Replace with (optional)", text: $newReplacement)
                    .textFieldStyle(.roundedBorder)
            }

            thresholdEditorRow(
                threshold: $newThreshold,
                label: "Matching threshold"
            )

            HStack {
                Spacer()
                Button("Cancel") {
                    isAdding = false
                    newWord = ""
                    newReplacement = ""
                    newThreshold = 0.85
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(MuesliTheme.textTertiary)

                Button("Add") {
                    let trimmedWord = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedWord.isEmpty else { return }
                    let replacement = newReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
                    controller.addCustomWord(
                        CustomWord(
                            word: trimmedWord,
                            replacement: replacement.isEmpty ? nil : replacement,
                            matchingThreshold: newThreshold
                        )
                    )
                    isAdding = false
                    newWord = ""
                    newReplacement = ""
                    newThreshold = 0.85
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MuesliTheme.accent)
                .disabled(newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(MuesliTheme.spacing16)
    }

    @ViewBuilder
    private func thresholdEditorRow(threshold: Binding<Double>, label: String) -> some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Text(label)
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
            Slider(value: threshold, in: 0.70...0.95, step: 0.01)
                .tint(MuesliTheme.accent)
            Text(threshold.wrappedValue.formattedThreshold)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MuesliTheme.textSecondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private func importVocabularyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .commaSeparatedText, .tabSeparatedText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                importVocabularyText(text)
            } catch {
                importMessage = nil
                importError = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    private func importVocabularyText(_ text: String) {
        let words = DictionaryImportParser.parse(text)
        guard !words.isEmpty else {
            importMessage = nil
            importError = "No valid terms found. Use one term per line, or word,replacement,threshold."
            return
        }
        let count = controller.importCustomWords(words)
        bulkImportText = ""
        showBulkImport = false
        importError = nil
        importMessage = "Imported \(count) vocabulary term\(count == 1 ? "" : "s")."
    }
}

private struct DictionaryWordEditorRow: View {
    let word: CustomWord
    let controller: MuesliController

    @State private var draftWord: String
    @State private var draftReplacement: String
    @State private var draftThreshold: Double

    init(word: CustomWord, controller: MuesliController) {
        self.word = word
        self.controller = controller
        _draftWord = State(initialValue: word.word)
        _draftReplacement = State(initialValue: word.replacement ?? "")
        _draftThreshold = State(initialValue: word.matchingThreshold)
    }

    private var trimmedWord: String {
        draftWord.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedReplacement: String {
        draftReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        trimmedWord != word.word
            || (trimmedReplacement.isEmpty ? nil : trimmedReplacement) != word.replacement
            || abs(draftThreshold - word.matchingThreshold) > 0.001
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(spacing: MuesliTheme.spacing12) {
                TextField("Word", text: $draftWord)
                    .textFieldStyle(.roundedBorder)
                TextField("Replace with (optional)", text: $draftReplacement)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: MuesliTheme.spacing12) {
                Text("Matching threshold")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
                Slider(value: $draftThreshold, in: 0.70...0.95, step: 0.01)
                    .tint(MuesliTheme.accent)
                Text(draftThreshold.formattedThreshold)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .frame(width: 36, alignment: .trailing)
            }

            HStack {
                Spacer()
                Button("Delete") {
                    controller.removeCustomWord(id: word.id)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(MuesliTheme.recording)

                Button("Save") {
                    controller.updateCustomWord(
                        CustomWord(
                            id: word.id,
                            word: trimmedWord,
                            replacement: trimmedReplacement.isEmpty ? nil : trimmedReplacement,
                            matchingThreshold: draftThreshold
                        )
                    )
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MuesliTheme.accent)
                .disabled(trimmedWord.isEmpty || !hasChanges)
            }
        }
        .padding(MuesliTheme.spacing16)
    }
}

private extension Double {
    var formattedThreshold: String {
        String(format: "%.2f", self)
    }
}
