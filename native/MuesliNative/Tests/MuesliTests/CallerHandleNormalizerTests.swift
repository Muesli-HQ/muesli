import Foundation
import MuesliCore
import Testing

@Suite("Caller handle normalization")
struct CallerHandleNormalizerTests {
    @Test("Formatted international numbers converge on one key")
    func formattedInternationalConverges() throws {
        let formatted = try #require(CallerHandleNormalizer.phone("+1 (202) 555-0123", region: nil))
        let compact = try #require(CallerHandleNormalizer.phone("+12025550123", region: "US"))
        #expect(formatted.kind == .phone)
        #expect(formatted.key == "phone:+12025550123")
        #expect(compact.key == formatted.key)
        #expect(formatted.displayValue == "+1 (202) 555-0123")
    }

    @Test("National numbers need a region and never equal international keys")
    func nationalRequiresRegionAndStaysDistinct() throws {
        #expect(CallerHandleNormalizer.phone("202-555-0123", region: nil) == nil)
        #expect(CallerHandleNormalizer.phone("202-555-0123", region: "usa") == nil)
        let national = try #require(CallerHandleNormalizer.phone("202-555-0123", region: "US"))
        #expect(national.key == "phone-national:US:2025550123")
        #expect(national.key != CallerHandleNormalizer.phone("+12025550123", region: nil)?.key)
    }

    @Test("Text that is not exactly one phone number is rejected", arguments: [
        "Call me at +12025550123",
        "+12025550123, +12025550124",
        "+1202555\u{202E}0123",
        "+12345",
        "+1234567890123456",
        "(20)2) 555",
        "((202)) 5550123",
        "+12025550123 ext 12",
        "+12025550123 x12",
        "+12025550123;12",
        "+12025550123#4",
        "2026-09-27",
        "09-27-2026",
        "27.09.2026",
        "09/27/2026",
        "12:30",
        "27-09-2026",
        "2026.09.27",
        "2026 09 27",
        "",
        "   ",
        "+0123456789",
    ])
    func rejectsNonNumbers(_ raw: String) {
        #expect(CallerHandleNormalizer.phone(raw, region: "US") == nil)
        #expect(CallerHandleNormalizer.handle(raw, region: "US") == nil)
    }

    @Test("Directional marks and non-breaking punctuation around a handle are accepted")
    func directionalMarksAndNonBreakingPunctuationAccepted() throws {
        let wrapped = try #require(CallerHandleNormalizer.phone("\u{202A}+1 (202) 555-0123\u{202C}", region: nil))
        #expect(wrapped.key == "phone:+12025550123")
        #expect(wrapped.displayValue == "+1 (202) 555-0123")
        let nonBreaking = CallerHandleNormalizer.phone("\u{2066}+1\u{00A0}202\u{00A0}555\u{2011}0123\u{2069}", region: nil)
        #expect(nonBreaking?.key == "phone:+12025550123")
        #expect(CallerHandleNormalizer.email("\u{200E}alice@example.test\u{200E}")?.key == "email:alice@example.test")
        #expect(CallerHandleNormalizer.phone("+1202555\u{202E}0123", region: nil) == nil)
    }

    @Test("Emails canonicalize the whole address without changing display text")
    func emailCanonicalization() throws {
        let email = try #require(CallerHandleNormalizer.email(" Alice+sales@EXAMPLE.test "))
        #expect(email.kind == .email)
        #expect(email.key == "email:alice+sales@example.test")
        #expect(email.displayValue == "Alice+sales@EXAMPLE.test")
        #expect(CallerHandleNormalizer.handle("Alice+sales@EXAMPLE.test", region: "US")?.key == email.key)
        #expect(CallerHandleNormalizer.email("alice+sales@example.test")?.key == email.key)
        #expect(CallerHandleNormalizer.email("a@b@c.test") == nil)
        #expect(CallerHandleNormalizer.email("a b@c.test") == nil)
        #expect(CallerHandleNormalizer.email("alice@example") == nil)
        #expect(CallerHandleNormalizer.email("mail alice@example.test") == nil)
    }

    @Test("UUIDv5 matches the RFC 4122 vector and the caller namespace")
    func uuidV5MatchesRFCVector() throws {
        let dns = try #require(UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8"))
        #expect(
            CallerHandleNormalizer.uuidV5(namespace: dns, name: "www.example.com")
                == UUID(uuidString: "2ed6657d-e927-568b-95e1-2665a8aea6a2")
        )
        #expect(
            CallerHandleNormalizer.personID(forKey: "phone:+12025550123")
                == UUID(uuidString: "086aa82b-2ca7-5f63-b6b9-9a94cc45b53c")
        )
    }
}
