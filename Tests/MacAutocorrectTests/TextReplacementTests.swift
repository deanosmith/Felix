import Foundation
import Darwin

@main
@MainActor
enum TextReplacementTests {
    static func main() async {
        let checks: [(String, @MainActor () async throws -> Void)] = [
            ("shortcut priority", testNativeShortcutTakesPriorityOverPersonalRule),
            ("capital correction priority", testNativeShortcutTakesPriorityOverCapitalCorrection),
            ("expanded text", testExpandedTextIsNotCorrectedAgain),
            ("space repair overlap", testNativeShortcutInsideSpaceRepairIsProtected),
            ("incomplete multiword shortcut", testMultiwordNativeShortcutIsProtectedWhileBeingTyped),
            ("case, punctuation and nonbreaking spaces", testNativeMatchingHandlesCapitalisationPunctuationAndNonbreakingSpaces),
            ("word boundaries", testNativeMatchingDoesNotProtectSubstringsOfOtherWords),
            ("unrelated rules", testUnrelatedNativeRulesDoNotDisableOrth),
            ("unrelated earlier text", testNativeTextElsewhereDoesNotDisableOrth),
            ("original typing examples", testOriginalTypingExamplesStillWork)
        ]
        var failures = 0
        for (name, check) in checks {
            do {
                try await check()
                print("PASS: \(name)")
            } catch {
                failures += 1
                print("FAIL: \(name): \(error)")
            }
        }
        print("\(checks.count - failures)/\(checks.count) checks passed")
        if failures > 0 { exit(EXIT_FAILURE) }
    }

    static func testNativeShortcutTakesPriorityOverPersonalRule() async throws {
        let candidate = try await correction("thiis ", replacements: ["thiis": "My replacement"])
        try expect(candidate == nil, "Orth rewrote a native shortcut")
    }

    static func testNativeShortcutTakesPriorityOverCapitalCorrection() async throws {
        let candidate = try await correction("THis ", replacements: ["THis": "My replacement"])
        try expect(candidate == nil, "Orth recased a native shortcut")
    }

    static func testExpandedTextIsNotCorrectedAgain() async throws {
        let candidate = try await correction(
            "My phrase thiis ", replacements: ["shortcut": "My phrase thiis"]
        )
        try expect(candidate == nil, "Orth rewrote an expanded native phrase")
    }

    static func testNativeShortcutInsideSpaceRepairIsProtected() async throws {
        let candidate = try await correction("Thi s ", replacements: ["thi": "My replacement"])
        try expect(candidate == nil, "Space repair consumed a native shortcut")
    }

    static func testMultiwordNativeShortcutIsProtectedWhileBeingTyped() async throws {
        let candidate = try await correction("thiis ", replacements: ["thiis phrase": "My replacement"])
        try expect(candidate == nil, "Orth rewrote the start of a multiword shortcut")
    }

    static func testNativeMatchingHandlesCapitalisationPunctuationAndNonbreakingSpaces() async throws {
        for text in ["Thiis ", "hello thiis! ", "hello\u{00A0}thiis\u{00A0}"] {
            let candidate = try await correction(text, replacements: ["thiis": "My replacement"])
            try expect(candidate == nil, "Native shortcut was rewritten: \(text)")
        }
        let candidate = try await correction(
            "My\u{00A0}phrase\u{00A0}thiis ",
            replacements: ["shortcut": "My phrase thiis"]
        )
        try expect(candidate == nil, "Native phrase with nonbreaking spaces was rewritten")
    }

    static func testNativeMatchingDoesNotProtectSubstringsOfOtherWords() async throws {
        var profile = TypingProfile()
        profile.replacements = ["bthiis": "this", "thiisb": "this"]
        for text in ["bthiis ", "thiisb "] {
            let candidate = try await correction(
                text, replacements: ["thiis": "My replacement"], profile: profile
            )
            try expect(candidate?.replacement == "this", "An unrelated word was protected: \(text)")
        }
    }

    static func testUnrelatedNativeRulesDoNotDisableOrth() async throws {
        let candidate = try await correction("thiis ", replacements: ["other": "Unrelated phrase"])
        try expect(candidate?.replacement == "this", "Unrelated rules disabled Orth")
        try expect(candidate?.range == NSRange(location: 0, length: 5), "Incorrect correction range")
    }

    static func testNativeTextElsewhereDoesNotDisableOrth() async throws {
        let candidate = try await correction("other thiis ", replacements: ["other": "My replacement"])
        try expect(candidate?.replacement == "this", "An earlier shortcut disabled Orth")
    }

    static func testOriginalTypingExamplesStillWork() async throws {
        for (text, expected) in [
            ("THis ", "This"), ("thiis ", "this"),
            ("Thi sdog ", "This dog"), ("Thi s ", "This")
        ] {
            let candidate = try await correction(text)
            try expect(candidate?.replacement == expected, "Original typing correction failed: \(text)")
            if let candidate {
                try expect(
                    (text as NSString).substring(with: candidate.range) == candidate.original,
                    "Incorrect original text range: \(text)"
                )
            }
        }
    }

    private static func correction(
        _ text: String, replacements: [String: String] = [:],
        profile: TypingProfile = TypingProfile()
    ) async throws -> CorrectionCandidate? {
        let domain = "Orth.TextReplacementTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else {
            throw CheckFailure(description: "Unable to create isolated test preferences")
        }
        let policy = CorrectionPolicy(defaults: defaults, replacementProvider: { replacements })
        return await policy.correction(
            in: text, caretOffset: (text as NSString).length,
            sensitivity: .aggressive, profile: profile
        )
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(description: message) }
    }

    private struct CheckFailure: Error, CustomStringConvertible {
        let description: String
    }
}
