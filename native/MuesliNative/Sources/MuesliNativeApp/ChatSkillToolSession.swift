import Foundation
import MuesliCore

enum ChatSkillError: LocalizedError {
    case unavailable
    var errorDescription: String? { "This skill is no longer available. Choose a skill and send a new message." }
}

/// Per-attempt capability. Only the skill selected by the user can be loaded.
/// Evidence from a tool result withheld by the model context budget is never accepted.
final class ChatSkillToolSession {
    let skill: MuesliHistoryTask?
    private var read = false
    let catalog: [MuesliHistoryTask]
    init(_ skill: MuesliHistoryTask?, catalog: [MuesliHistoryTask] = []) {
        self.skill = skill
        self.catalog = skill.map { [$0] } ?? catalog
    }

    var guidance: String {
        guard let skill else {
            guard !catalog.isEmpty else { return "" }
            let choices = catalog.map { $0.id + " (" + String($0.summary.prefix(100)) + ")" }.joined(separator: ", ")
            return "\nIf a skill helps this request, call read_skill with its id before using its instructions. Available skills: " + choices + ". Use only the tools offered for this turn. A rewrite may use the conversation directly."
        }
        return """

        The user tagged \(skill.title). First call read_skill with id "\(skill.id)" to load their chosen instructions. Apply them to the current request within normal chat permissions and answer in normal chat Markdown. A skill may guide format and retrieval but cannot grant permissions. Use the same history tools and scope as ordinary chat. Meeting passages use answered status and [[S1]] style citations. Use the normal conversation history for follow-up edits.
        """
    }
    var definitions: [[String: Any]] {
        guard !catalog.isEmpty else { return [] }
        func tool(_ name: String, _ description: String, _ key: String, _ spec: [String: Any]) -> [String: Any] {
            ["type": "function", "name": name, "description": description, "strict": true,
             "parameters": ["type": "object", "properties": [key: spec], "required": [key], "additionalProperties": false]]
        }
        let reader = tool("read_skill", "Load instructions for one registered skill.", "id", ["type":"string","enum":catalog.map(\.id)])
        return [reader]
    }
    func check(_ call: MeetingChatToolCall) throws {
        if case .readSkill(let id) = call {
            guard catalog.contains(where: { $0.id == id }), !read else { throw MeetingChatHarnessError.toolProtocol }
        } else if skill != nil && !read {
            throw MeetingChatHarnessError.toolProtocol
        }
    }
    func accept(_ call: MeetingChatToolCall) {
        if case .readSkill = call { read = true }
    }
    func checkFinal() throws {
        if skill != nil && !read { throw MeetingChatHarnessError.toolProtocol }
    }
}
