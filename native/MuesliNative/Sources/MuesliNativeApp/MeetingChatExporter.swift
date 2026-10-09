import AppKit
import MuesliCore

enum MeetingChatExporter {
    static func markdown(turn: MeetingChatTurn, session: MeetingChatSession, useEditedDraft: Bool) -> String {
        var answer = MeetingChatClient.displayText(useEditedDraft ? turn.editableDraft ?? turn.originalAnswer ?? "" : turn.originalAnswer ?? "")
        for (index, source) in turn.citations.enumerated() { answer = answer.replacingOccurrences(of: "[[\(source.sourceKey)]]", with: "[\(index + 1)]") }
        var parts = ["# \(session.title)", "", "**Question:** \(turn.question)", "**AI:** \(turn.provider) · \(turn.model)", ""]
        if let scopeLabel = turn.scopeLabel { parts += ["**Context:** " + scopeLabel, ""] }
        if useEditedDraft && turn.editableDraft != nil { parts += ["*Edited draft — source references belong to the original answer.*", ""] }
        parts += [answer, "", "## Sources", ""]
        for (index, source) in turn.citations.enumerated() {
            parts += ["[\(index + 1)] **\(source.title)** — \(source.startDate.formatted(date: .abbreviated, time: .shortened)) · \(source.kind.label)\(source.timestamp.map { " · \($0)" } ?? "")", ""]
            // Indented code prevents meeting text from becoming active Markdown links/images/HTML.
            parts += source.excerpt.components(separatedBy: .newlines).map { "    " + $0 }
            parts.append("")
        }
        if let coverage = turn.coverage { parts += ["\(coverage.isPartialRecap ? "Partial recap. " : "")Evidence from \(coverage.evidenceMeetingCount) of \(coverage.eligibleMeetingCount) eligible saved meetings.", ""] }
        return parts.joined(separator: "\n")
    }
    static func plainText(turn: MeetingChatTurn, session: MeetingChatSession, useEditedDraft: Bool) -> String {
        markdown(turn: turn, session: session, useEditedDraft: useEditedDraft).replacingOccurrences(of: "**", with: "")
    }
    @MainActor static func save(markdown: String, destination: URL?, pdf: Bool) throws {
        guard let destination else { return }
        if pdf { try MeetingExporter.writePDF(attributed: MeetingExporter.buildAttributedString(from: markdown), to: destination) }
        else { try markdown.write(to: destination, atomically: true, encoding: .utf8) }
    }
    @MainActor static func export(turn: MeetingChatTurn, session: MeetingChatSession, useEditedDraft: Bool) {
        let content = markdown(turn: turn, session: session, useEditedDraft: useEditedDraft)
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Meeting answer.md"; panel.allowedContentTypes = [MeetingExporter.mdType]
        let picker = ExportFormatAccessory(panel: panel); panel.accessoryView = picker.view
        MeetingExporter.presentSavePanel(panel) { destination in
            do { try save(markdown: content, destination: destination, pdf: picker.selectedFormat == .pdf); NSWorkspace.shared.open(destination) }
            catch { let alert = NSAlert(); alert.messageText = "Export failed"; alert.informativeText = error.localizedDescription; alert.runModal() }
        }
    }
}
