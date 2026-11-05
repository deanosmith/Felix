import Foundation
import OSLog

struct TypingProfile: Codable, Equatable, Sendable {
    var fixesCapitals = true
    var fixesRepeatedLetters = true
    var fixesSpaces = true
    var replacements = ["thiis": "this", "thi s": "this"]

    static func load(from defaults: UserDefaults = .standard) -> TypingProfile {
        guard let data = defaults.data(forKey: "typingProfile") else { return TypingProfile() }
        do {
            let profile = try JSONDecoder().decode(TypingProfile.self, from: data)
            guard profile.replacements.allSatisfy({
                isValidPhrase($0.key) && isValidPhrase($0.value) && $0.key != $0.value
            }) else {
                throw ProfileError.invalidReplacement
            }
            return profile
        } catch {
            Logger(subsystem: "local.deanmsmith.Felix", category: "Correction")
                .error("Unable to load typing profile: \(error.localizedDescription, privacy: .public)")
            return TypingProfile()
        }
    }

    func save(to defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: "typingProfile")
    }

    var replacementText: String {
        replacements.sorted { $0.key < $1.key }
            .map { "\($0.key) = \($0.value)" }.joined(separator: "\n")
    }

    static func parseReplacements(_ text: String) throws -> [String: String] {
        var replacements: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let parts = line.components(separatedBy: "=")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, isValidPhrase(parts[0]), isValidPhrase(parts[1]),
                  parts[0] != parts[1], replacements[parts[0]] == nil
            else { throw ProfileError.invalidReplacement }
            replacements[parts[0]] = parts[1]
        }
        return replacements
    }

    private static func isValidPhrase(_ text: String) -> Bool {
        let words = text.components(separatedBy: " ")
        return (1...2).contains(words.count) && words.allSatisfy {
            (1...32).contains($0.count)
                && $0.unicodeScalars.allSatisfy { (97...122).contains($0.value) }
        }
    }

    enum ProfileError: LocalizedError {
        case invalidReplacement

        var errorDescription: String? {
            "Use one replacement per line: typo = correction. Each side must contain one or two lowercase English words, up to 32 letters each. Duplicate typos and unchanged replacements are not allowed."
        }
    }
}
