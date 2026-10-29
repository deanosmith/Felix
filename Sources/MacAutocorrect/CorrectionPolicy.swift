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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ignoredWords = Set((defaults.stringArray(forKey: "ignoredWords") ?? []).map { $0.lowercased() })
    }

    func prepare() {
        _ = language
        _ = documentTag
    }

    func correction(
        in text: String, caretOffset: Int, sensitivity: CorrectionSensitivity = .conservative
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
        let lowercase = word.lowercased()
        let titlecase = lowercase.prefix(1).uppercased() + lowercase.dropFirst()
        let minimumLength = sensitivity == .aggressive ? 2 : 3

        guard (minimumLength...32).contains(word.count),
              word.unicodeScalars.allSatisfy({
                  (97...122).contains($0.value) || (65...90).contains($0.value)
              }),
              word == lowercase || (sensitivity == .aggressive && word == titlecase),
              !ignoredWords.contains(lowercase),
              !token.hasPrefix("."), !token.hasPrefix(":"),
              !looksTechnical(prefix)
        else { return nil }

        let punctuationLength = (token as NSString).length - (word as NSString).length
        guard punctuationLength <= 1 else { return nil }

        let tokenRange = NSRange(tokenStart..<prefix.endIndex, in: prefix)
        let range = NSRange(location: tokenRange.location, length: (word as NSString).length)
        let spelling = spellChecker.checkSpelling(
            of: word,
            startingAt: 0,
            language: language,
            wrap: false,
            inSpellDocumentWithTag: documentTag,
            wordCount: nil
        )
          guard spelling.location != NSNotFound, !Task.isCancelled,
              !isProperName(in: text, range: range), !Task.isCancelled
          else { return nil }

        let automatic = spellChecker.correction(
            forWordRange: range,
            in: text,
            language: language,
            inSpellDocumentWithTag: documentTag
        )
        var replacement = automatic.flatMap { normalizedReplacement($0, for: word) }
        if replacement == nil, sensitivity != .conservative {
            let guesses = spellChecker.guesses(
                forWordRange: range, in: text, language: language,
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
        ignoredWords.insert(word.lowercased())
        defaults.set(ignoredWords.sorted(), forKey: "ignoredWords")
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