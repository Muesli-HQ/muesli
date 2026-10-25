import Foundation

/// Local-only recipient entry. Invalid or excess addresses remain visible and block upload.
struct SharingRecipientInput {
    var emails: [String] = []
    var draft = ""
    var error: String?

    static func isValid(_ email: String) -> Bool {
        email.count <= 254
            && email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }

    var isReady: Bool {
        !emails.isEmpty && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && emails.count <= 10 && emails.allSatisfy(Self.isValid)
    }

    mutating func commit() {
        let candidates = draft.components(separatedBy: CharacterSet(charactersIn: ",;\n\t "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        var remaining: [String] = []
        var invalid = false
        var overLimit = false
        for email in candidates {
            guard Self.isValid(email) else {
                remaining.append(email)
                invalid = true
                continue
            }
            guard !emails.contains(email) else { continue }
            guard emails.count < 10 else {
                remaining.append(email)
                overLimit = true
                continue
            }
            emails.append(email)
        }
        draft = remaining.joined(separator: " ")
        error = invalid ? "Enter a complete email address." : (overLimit ? "You can invite up to 10 people." : nil)
    }

    mutating func remove(_ email: String) {
        emails.removeAll { $0 == email }
        if draft.isEmpty { error = nil }
    }
}
