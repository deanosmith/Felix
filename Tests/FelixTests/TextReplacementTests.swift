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
            ("unrelated rules", testUnrelatedNativeRulesDoNotDisableFelix),
            ("unrelated earlier text", testNativeTextElsewhereDoesNotDisableFelix),
            ("original typing examples", testOriginalTypingExamplesStillWork),
            ("insert-first replacement", testInsertFirstReplacementPreservesSeparators),
            ("rejected insertion", testRejectedInsertionNeverDeletesOriginal),
            ("unverified insertion", testUnverifiedInsertionNeverDeletesOriginal),
            ("rejected removal", testRejectedRemovalPreservesBothTexts),
            ("partial removal", testPartialRemovalPreservesReplacement),
            ("unverified replacement", testUnverifiedReplacementIsNotReportedAsSuccess)
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
        try expect(candidate == nil, "Felix rewrote a native shortcut")
    }

    static func testNativeShortcutTakesPriorityOverCapitalCorrection() async throws {
        let candidate = try await correction("THis ", replacements: ["THis": "My replacement"])
        try expect(candidate == nil, "Felix recased a native shortcut")
    }

    static func testExpandedTextIsNotCorrectedAgain() async throws {
        let candidate = try await correction(
            "My phrase thiis ", replacements: ["shortcut": "My phrase thiis"]
        )
        try expect(candidate == nil, "Felix rewrote an expanded native phrase")
    }

    static func testNativeShortcutInsideSpaceRepairIsProtected() async throws {
        let candidate = try await correction("Thi s ", replacements: ["thi": "My replacement"])
        try expect(candidate == nil, "Space repair consumed a native shortcut")
    }

    static func testMultiwordNativeShortcutIsProtectedWhileBeingTyped() async throws {
        let candidate = try await correction("thiis ", replacements: ["thiis phrase": "My replacement"])
        try expect(candidate == nil, "Felix rewrote the start of a multiword shortcut")
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

    static func testUnrelatedNativeRulesDoNotDisableFelix() async throws {
        let candidate = try await correction("thiis ", replacements: ["other": "Unrelated phrase"])
        try expect(candidate?.replacement == "this", "Unrelated rules disabled Felix")
        try expect(candidate?.range == NSRange(location: 0, length: 5), "Incorrect correction range")
    }

    static func testNativeTextElsewhereDoesNotDisableFelix() async throws {
        let candidate = try await correction("other thiis ", replacements: ["other": "My replacement"])
        try expect(candidate?.replacement == "this", "An earlier shortcut disabled Felix")
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

    static func testInsertFirstReplacementPreservesSeparators() throws {
        for (original, replacement) in [
            ("thiis ", "this "), ("thiis!\u{00A0}", "this!\u{00A0}"),
            ("Thi sdog ", "This dog ")
        ] {
            let result = replacementTransaction(original: original, replacement: replacement)
            try expect(result.success, "Insert-first replacement was rejected")
            try expect(result.text == replacement, "Replacement changed the word or separators")
            try expect(
                result.operations == ["insert", "verifyInsertion", "removeOriginal", "verifyReplacement"],
                "Original text was removed before insertion was verified"
            )
        }
    }

    static func testRejectedInsertionNeverDeletesOriginal() throws {
        let result = replacementTransaction(failing: "insert")
        try expect(!result.success && result.text == "thiis ", "Rejected insertion lost original text")
        try expect(result.operations == ["insert"], "Removal ran after rejected insertion")
    }

    static func testUnverifiedInsertionNeverDeletesOriginal() throws {
        let result = replacementTransaction(failing: "verifyInsertion")
        try expect(!result.success && result.text == "this thiis ", "Unverified insertion lost original text")
        try expect(
            result.operations == ["insert", "verifyInsertion"],
            "Removal ran after insertion verification failed"
        )
    }

    static func testRejectedRemovalPreservesBothTexts() throws {
        let result = replacementTransaction(failing: "removeOriginal")
        try expect(!result.success && result.text == "this thiis ", "Rejected removal lost text")
        try expect(!result.operations.contains("verifyReplacement"), "Rejected removal reported success")
    }

    static func testPartialRemovalPreservesReplacement() throws {
        let result = replacementTransaction(removalCount: 2)
        try expect(!result.success, "Partial removal reported success")
        try expect(result.text == "this iis ", "Partial removal deleted the confirmed replacement")
    }

    static func testUnverifiedReplacementIsNotReportedAsSuccess() throws {
        let result = replacementTransaction(failing: "verifyReplacement")
        try expect(!result.success && result.text == "this ", "Unverified replacement lost text or reported success")
    }

    private static func replacementTransaction(
        original: String = "thiis ", replacement: String = "this ",
        failing operation: String? = nil, removalCount: Int? = nil
    ) -> (success: Bool, text: String, operations: [String]) {
        var text = original
        var operations: [String] = []
        let success = TextReplacementTransaction.apply(
            insert: {
                operations.append("insert")
                guard operation != "insert" else { return false }
                text = replacement + text
                return true
            },
            verifyInsertion: {
                operations.append("verifyInsertion")
                return operation != "verifyInsertion" && text == replacement + original
            },
            removeOriginal: {
                operations.append("removeOriginal")
                guard operation != "removeOriginal" else { return false }
                let range = NSRange(
                    location: (replacement as NSString).length,
                    length: removalCount ?? (original as NSString).length
                )
                text = (text as NSString).replacingCharacters(in: range, with: "")
                return true
            },
            verifyReplacement: {
                operations.append("verifyReplacement")
                return operation != "verifyReplacement" && text == replacement
            }
        )
        return (success, text, operations)
    }

    private static func correction(
        _ text: String, replacements: [String: String] = [:],
        profile: TypingProfile = TypingProfile()
    ) async throws -> CorrectionCandidate? {
        let domain = "Felix.TextReplacementTests.\(UUID().uuidString)"
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
