import CryptoKit
import Foundation

public enum CallerHandleKind: String, Sendable {
    case phone
    case email
}

/// A phone number or email address that identified a caller.
///
/// `key` is the canonical identity used to find the same person again;
/// `displayValue` is the text as the calling app showed it.
public struct CallerHandle: Sendable, Hashable {
    public let kind: CallerHandleKind
    public let key: String
    public let displayValue: String

    public init(kind: CallerHandleKind, key: String, displayValue: String) {
        self.kind = kind
        self.key = key
        self.displayValue = displayValue
    }
}

/// Validates a whole string as one caller handle. It never extracts a number
/// from surrounding text and never guesses a country code.
public enum CallerHandleNormalizer {
    private static let personNamespace = UUID(uuidString: "559275fb-2467-5ef4-b428-b6fc3ec91c04")!

    public static func handle(_ raw: String, region: String?) -> CallerHandle? {
        email(raw) ?? phone(raw, region: region)
    }

    public static func phone(_ raw: String, region: String?) -> CallerHandle? {
        let text = cleaned(raw)
        guard !text.isEmpty, isSafe(text),
              text.range(of: #"^\+?[0-9() .\-]+$"#, options: .regularExpression) != nil,
              !dateShapes.contains(where: { text.range(of: $0, options: .regularExpression) != nil }),
              hasValidParentheses(text) else {
            return nil
        }
        let digits = text.filter(\.isASCIIDigit)
        guard (7...15).contains(digits.count) else { return nil }

        if text.hasPrefix("+") {
            guard digits.first != "0" else { return nil }
            return CallerHandle(kind: .phone, key: "phone:+" + digits, displayValue: text)
        }
        guard let region, region.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil else {
            return nil
        }
        return CallerHandle(kind: .phone, key: "phone-national:\(region):\(digits)", displayValue: text)
    }

    public static func email(_ raw: String) -> CallerHandle? {
        let text = cleaned(raw)
        guard isSafe(text),
              text.range(of: #"^[^@\s|]+@[^@\s|]+\.[^@\s|.]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return CallerHandle(
            kind: .email,
            key: "email:\(text.lowercased())",
            displayValue: text
        )
    }

    public static func personID(forKey key: String) -> UUID {
        uuidV5(namespace: personNamespace, name: key)
    }

    public static func uuidV5(namespace: UUID, name: String) -> UUID {
        var data = withUnsafeBytes(of: namespace.uuid) { Data($0) }
        data.append(contentsOf: Array(name.utf8))
        var bytes = Array(Insecure.SHA1.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Dates such as 2026-09-27, 27.09.2026 or 2026 09 27 are made of digits
    /// and separators but are never caller numbers.
    private static let dateShapes = [
        #"^\d{4}[-. ]\d{2}[-. ]\d{2}$"#,
        #"^\d{2}[-. ]\d{2}[-. ]\d{4}$"#,
    ]

    private static let directionalMarks = CharacterSet(charactersIn:
        "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")

    /// Apple UIs wrap numbers in directional marks and use non-breaking spaces
    /// and hyphens. Strips marks around the whole string and maps that
    /// punctuation to ASCII; marks inside the string are left for `isSafe`.
    private static func cleaned(_ raw: String) -> String {
        let unwrapped = raw.trimmingCharacters(in: directionalMarks.union(.whitespacesAndNewlines))
        return String(unwrapped.map { character -> Character in
            switch character {
            case "\u{00A0}", "\u{202F}", "\u{2007}": return " "
            case "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}": return "-"
            default: return character
            }
        })
    }

    private static func isSafe(_ text: String) -> Bool {
        !text.unicodeScalars.contains {
            $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
        }
    }

    /// Allows at most one non-nested pair, e.g. `(202) 555-0123`.
    private static func hasValidParentheses(_ text: String) -> Bool {
        let opens = text.filter { $0 == "(" }.count
        let closes = text.filter { $0 == ")" }.count
        guard opens == closes, opens <= 1 else { return false }
        guard opens == 1,
              let open = text.firstIndex(of: "("),
              let close = text.firstIndex(of: ")") else {
            return true
        }
        return open < close && text[text.index(after: open)..<close].contains(where: \.isASCIIDigit)
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
