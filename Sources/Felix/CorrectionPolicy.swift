import AppKit
import NaturalLanguage

enum CorrectionSensitivity: String, CaseIterable, Sendable {
    case conservative
    case balanced
    case aggressive

    var title: String { rawValue.capitalized }
}

struct CorrectionCandidate: Sendable {
    let original: String
    let replacement: String
    let range: NSRange
}

actor CorrectionPolicy {
    private lazy var spellChecker = NSSpellChecker.shared
    private lazy var documentTag = NSSpellChecker.uniqueSpellDocumentTag()
    private lazy var nameTagger = NLTagger(tagSchemes: [.nameType])
    private lazy var language = spellChecker.userPreferredLanguages.first(where: { $0.hasPrefix("en") })
        ?? spellChecker.availableLanguages.first(where: { $0.hasPrefix("en") })
        ?? "en_US"
    private let defaults: UserDefaults
    private var ignoredWords: Set<String>
    private let replacementProvider: @Sendable () -> [String: String]

    init(
        defaults: UserDefaults = .standard,
        replacementProvider: @escaping @Sendable () -> [String: String] = {
            NSSpellChecker.shared.userReplacementsDictionary
        }
    ) {
        self.defaults = defaults
        self.replacementProvider = replacementProvider
        ignoredWords = Set((defaults.stringArray(forKey: "ignoredWords") ?? []).map { $0.lowercased() })
    }

    func prepare() {
        _ = language
        _ = documentTag
    }

    func correction(
        in text: String, caretOffset: Int, sensitivity: CorrectionSensitivity = .conservative,
        profile: TypingProfile = TypingProfile()
    ) -> CorrectionCandidate? {
        guard let candidate = proposedCorrection(
            in: text, caretOffset: caretOffset, sensitivity: sensitivity, profile: profile
        ), !overlapsSystemReplacement(candidate, in: text, caretOffset: caretOffset)
        else { return nil }
        return candidate
    }

    private func overlapsSystemReplacement(
        _ candidate: CorrectionCandidate, in text: String, caretOffset: Int
    ) -> Bool {
        let prefix = (text as NSString).substring(to: caretOffset)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        var protected: Set<String> = []
        for (shortcut, expansion) in replacementProvider() {
            protected.insert(shortcut)
            protected.insert(expansion)
            // Do not rewrite the first word before a multiword shortcut is complete.
            for index in shortcut.indices where shortcut[index].isWhitespace {
                protected.insert(String(shortcut[..<index]))
            }
        }

        func isWordCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "_"
        }

        for phrase in protected {
            let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\u{00A0}", with: " ")
            guard let first = phrase.first, let last = phrase.last else { continue }
            var start = prefix.startIndex
            while let match = prefix.range(
                of: phrase, options: .caseInsensitive, range: start..<prefix.endIndex
            ) {
                let startsAtBoundary = !isWordCharacter(first) || match.lowerBound == prefix.startIndex
                    || !isWordCharacter(prefix[prefix.index(before: match.lowerBound)])
                let endsAtBoundary = !isWordCharacter(last) || match.upperBound == prefix.endIndex
                    || !isWordCharacter(prefix[match.upperBound])
                if startsAtBoundary, endsAtBoundary,
                   NSIntersectionRange(candidate.range, NSRange(match, in: prefix)).length > 0 {
                    return true
                }
                start = match.upperBound
            }
        }
        return false
    }

    private func proposedCorrection(
        in text: String, caretOffset: Int, sensitivity: CorrectionSensitivity,
        profile: TypingProfile
    ) -> CorrectionCandidate? {
        guard !Task.isCancelled else { return nil }
        let source = text as NSString
        guard caretOffset > 1, caretOffset <= source.length,
              source.substring(with: NSRange(location: caretOffset - 1, length: 1))
                .allSatisfy(\.isWhitespace)
        else { return nil }

        let prefix = source.substring(to: caretOffset - 1)
        guard let lastCharacter = prefix.last, !lastCharacter.isWhitespace else { return nil }

        let tokenStart = prefix.lastIndex(where: { $0.isWhitespace })
            .map { prefix.index(after: $0) } ?? prefix.startIndex
        let token = String(prefix[tokenStart...])
        let word = token.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:"))
        guard token == word || token == word + String(token.suffix(1)) else { return nil }
        if let previous = prefix[..<tokenStart].split(whereSeparator: { $0.isWhitespace }).last,
           ignoredWords.contains((previous + " " + word).lowercased()) {
            return nil
        }
        guard !looksTechnical(prefix) else { return nil }
        if let personal = personalCorrection(in: prefix, profile: profile) {
            return personal
        }
        let lowercase = word.lowercased()
        let titlecase = lowercase.prefix(1).uppercased() + lowercase.dropFirst()
        let minimumLength = sensitivity == .aggressive ? 2 : 3
        let hasDoubleInitialCapitals = word.count >= 3
            && word.prefix(2).allSatisfy(\.isUppercase)
            && word.dropFirst(2).allSatisfy(\.isLowercase)

        guard word == "i" || (minimumLength...32).contains(word.count),
              word.unicodeScalars.allSatisfy({
                  (97...122).contains($0.value) || (65...90).contains($0.value)
              }),
              word == lowercase || word == titlecase
                || (profile.fixesCapitals && hasDoubleInitialCapitals),
              !ignoredWords.contains(lowercase),
              !token.hasPrefix("."), !token.hasPrefix(":")
        else { return nil }

        // Leave configured split-word prefixes intact until the next word is complete.
        if profile.fixesSpaces, profile.replacements.keys.contains(where: {
            $0.hasPrefix(lowercase + " ") && token == word
        }) {
            return nil
        }

        let punctuationLength = (token as NSString).length - (word as NSString).length
        guard punctuationLength <= 1 else { return nil }

        let tokenRange = NSRange(tokenStart..<prefix.endIndex, in: prefix)
        let range = NSRange(location: tokenRange.location, length: (word as NSString).length)
        if word == "i" {
            return CorrectionCandidate(original: word, replacement: "I", range: range)
        }
        let spelling = spellChecker.checkSpelling(
            of: hasDoubleInitialCapitals ? titlecase : word,
            startingAt: 0,
            language: language,
            wrap: false,
            inSpellDocumentWithTag: documentTag,
            wordCount: nil
        )
        if spelling.location == NSNotFound, hasDoubleInitialCapitals, !Task.isCancelled {
            return CorrectionCandidate(original: word, replacement: titlecase, range: range)
        }
        // Initial capitalization alone must not make a typo look like a proper name.
        let spellingText = word == titlecase
            ? source.replacingCharacters(in: range, with: lowercase) : text
        guard spelling.location != NSNotFound, !Task.isCancelled,
              !isProperName(in: spellingText, range: range), !Task.isCancelled
        else { return nil }

        if profile.fixesRepeatedLetters,
           let replacement = repeatedLetterCorrection(for: word) {
            return CorrectionCandidate(original: word, replacement: replacement, range: range)
        }

        let automatic = spellChecker.correction(
            forWordRange: range,
            in: spellingText,
            language: language,
            inSpellDocumentWithTag: documentTag
        )
        var replacement = automatic.flatMap { normalizedReplacement($0, for: word) }
        if replacement == nil, sensitivity != .conservative {
            let guesses = spellChecker.guesses(
                forWordRange: range, in: spellingText, language: language,
                inSpellDocumentWithTag: documentTag
            ) ?? []
            for guess in guesses {
                guard let proposed = normalizedReplacement(guess, for: word) else { continue }
                if sensitivity == .balanced {
                    let difference = proposed.lowercased().difference(from: lowercase).count
                    guard difference <= (word.count <= 5 ? 2 : 4) else { continue }
                }
                replacement = proposed
                break
            }
        }
        guard let replacement else { return nil }

        return CorrectionCandidate(original: word, replacement: replacement, range: range)
    }

    func ignore(_ word: String) {
        ignoredWords.insert(word.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " "))
        defaults.set(ignoredWords.sorted(), forKey: "ignoredWords")
    }

    private func personalCorrection(in prefix: String, profile: TypingProfile) -> CorrectionCandidate? {
        let tokenStart = prefix.lastIndex(where: { $0.isWhitespace })
            .map { prefix.index(after: $0) } ?? prefix.startIndex
        let token = String(prefix[tokenStart...])
        let word = token.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:"))
        guard token == word || token == word + String(token.suffix(1)) else { return nil }

        var start = tokenStart
        if profile.fixesSpaces, tokenStart > prefix.startIndex {
            let separator = prefix.index(before: tokenStart)
            if prefix[separator] == " " || prefix[separator] == "\u{00A0}" {
                let before = prefix[..<separator]
                start = before.lastIndex(where: { $0.isWhitespace })
                    .map { prefix.index(after: $0) } ?? prefix.startIndex
            }
        }
        let preceding = String(prefix[start..<tokenStart])
        let phrase = preceding + word
        let normalizedPhrase = phrase.replacingOccurrences(of: "\u{00A0}", with: " ").lowercased()
        if profile.fixesSpaces, start < tokenStart,
           let replacement = profile.replacements[normalizedPhrase],
           canPersonalize(phrase, profile: profile) {
            return personalCandidate(phrase, replacement: replacement, start: start, in: prefix)
        }

        // Only move a stranded letter for an explicitly configured split, never a valid next word.
        if profile.fixesSpaces, start < tokenStart, !isSpelledCorrectly(word),
           canPersonalize(phrase, profile: profile) {
            var candidates: [String] = []
            for (typo, replacement) in profile.replacements {
                let parts = typo.split(separator: " ")
                guard parts.count == 2, parts[1].count == 1,
                      preceding.lowercased().trimmingCharacters(in: .whitespaces) == parts[0],
                      word.lowercased().hasPrefix(parts[1])
                else { continue }
                let remainder = String(word.dropFirst())
                guard remainder.count >= 2, isSpelledCorrectly(remainder),
                      !isProperName(in: prefix, range: NSRange(tokenStart..<prefix.endIndex, in: prefix))
                else { continue }
                candidates.append(replacement + " " + remainder)
            }
            if Set(candidates).count == 1, let replacement = candidates.first {
                return personalCandidate(phrase, replacement: replacement, start: start, in: prefix)
            }
        }

        guard let replacement = profile.replacements[word.lowercased()],
              profile.fixesSpaces || !replacement.contains(" "),
              canPersonalize(word, profile: profile)
        else { return nil }
        return personalCandidate(word, replacement: replacement, start: tokenStart, in: prefix)
    }

    private func canPersonalize(_ phrase: String, profile: TypingProfile) -> Bool {
        let lowercase = phrase.lowercased()
        guard !ignoredWords.contains(lowercase.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")),
              !phrase.split(whereSeparator: { $0.isWhitespace }).contains(where: {
                  ignoredWords.contains($0.lowercased())
              })
        else { return false }
        let titlecase = lowercase.prefix(1).uppercased() + lowercase.dropFirst()
        let firstWord = phrase.split(whereSeparator: { $0.isWhitespace }).first ?? ""
        let doubleCapitals = firstWord.count >= 3 && firstWord.prefix(2).allSatisfy(\.isUppercase)
            && firstWord.dropFirst(2).allSatisfy(\.isLowercase)
            && phrase.dropFirst(2) == lowercase.dropFirst(2)
        return phrase == lowercase || phrase == titlecase
            || (profile.fixesCapitals && doubleCapitals)
    }

    private func personalCandidate(
        _ original: String, replacement: String, start: String.Index, in prefix: String
    ) -> CorrectionCandidate {
        let cased = original.first?.isUppercase == true
            ? replacement.prefix(1).uppercased() + replacement.dropFirst() : replacement
        return CorrectionCandidate(
            original: original, replacement: cased,
            range: NSRange(location: NSRange(prefix.startIndex..<start, in: prefix).length,
                           length: (original as NSString).length)
        )
    }

    private func isSpelledCorrectly(_ word: String) -> Bool {
        guard word.count >= 2,
              word.unicodeScalars.allSatisfy({
                  (97...122).contains($0.value) || (65...90).contains($0.value)
              })
        else { return false }
        return spellChecker.checkSpelling(
            of: word.lowercased(), startingAt: 0, language: language, wrap: false,
            inSpellDocumentWithTag: documentTag, wordCount: nil
        ).location == NSNotFound
    }

    private func repeatedLetterCorrection(for word: String) -> String? {
        let letters = Array(word.lowercased())
        var candidates: Set<String> = []
        for index in 1..<letters.count where letters[index] == letters[index - 1] {
            var shortened = letters
            shortened.remove(at: index)
            let candidate = String(shortened)
            if isSpelledCorrectly(candidate) { candidates.insert(candidate) }
        }
        guard candidates.count == 1, let candidate = candidates.first else { return nil }
        return normalizedReplacement(candidate, for: word)
    }

    private func normalizedReplacement(_ suggestion: String, for word: String) -> String? {
        guard (2...40).contains(suggestion.count),
              suggestion.unicodeScalars.allSatisfy({
                  (97...122).contains($0.value) || (65...90).contains($0.value)
                      || $0.value == 39 || $0.value == 0x2019
              })
        else { return nil }

        let lowercase = suggestion.lowercased()
        let titlecase = lowercase.prefix(1).uppercased() + lowercase.dropFirst()
        let startsUppercase = word.first?.isUppercase == true
        guard lowercase != word.lowercased(),
              suggestion == lowercase || (startsUppercase && suggestion == titlecase)
        else { return nil }
        return startsUppercase ? titlecase : lowercase
    }

    private func looksTechnical(_ prefix: String) -> Bool {
        let line = prefix.components(separatedBy: .newlines).last ?? prefix
        let markers = CharacterSet(charactersIn: "`{}[]<>=\\/_$@#|")
        if line.rangeOfCharacter(from: markers) != nil { return true }
        if line.contains("://") || line.contains("::") || line.contains("->") { return true }

        let firstWord = line.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        return [
            "import", "from", "func", "def", "class", "struct", "enum", "let", "var",
            "const", "return", "export", "function", "SELECT", "INSERT", "UPDATE", "DELETE"
        ].contains(firstWord)
    }

    private func isProperName(in text: String, range: NSRange) -> Bool {
        guard let wordRange = Range(range, in: text) else { return true }
        nameTagger.string = text
        defer { nameTagger.string = nil }
        nameTagger.setLanguage(.english, range: text.startIndex..<text.endIndex)
        let (tag, _) = nameTagger.tag(at: wordRange.lowerBound, unit: .word, scheme: .nameType)
        return tag == .personalName || tag == .placeName || tag == .organizationName
    }
}