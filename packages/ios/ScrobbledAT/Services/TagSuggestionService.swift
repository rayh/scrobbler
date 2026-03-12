import Foundation
import NaturalLanguage

/// Extracts candidate tag keywords from free text using on-device NLP.
///
/// Uses `NLTagger` with `.lexicalClass` to keep only nouns and adjectives,
/// then filters stopwords and short tokens. No network required.
struct TagSuggestionService {

    /// Words that look like keywords but are useless as tags.
    private static let stopwords: Set<String> = [
        "this", "that", "just", "like", "love", "great", "good", "really",
        "very", "much", "more", "some", "song", "track", "music", "album",
        "listen", "listening", "playing", "heard", "hear", "sounds", "sound",
        "feel", "feeling", "makes", "think", "know", "want", "need", "going"
    ]

    /// Returns up to `limit` lowercase tag-worthy words extracted from `text`.
    static func keywords(from text: String, limit: Int = 5) -> [String] {
        guard !text.isEmpty else { return [] }

        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text

        var candidates: [(String, Int)] = []  // (word, frequency)
        var frequency: [String: Int] = [:]

        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .omitOther]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word,
                             scheme: .lexicalClass,
                             options: options) { tag, range in
            guard let tag,
                  tag == .noun || tag == .adjective else { return true }

            let word = String(text[range])
                .lowercased()
                .trimmingCharacters(in: .punctuationCharacters)

            guard word.count >= 4,
                  !stopwords.contains(word),
                  word.allSatisfy(\.isLetter) else { return true }

            frequency[word, default: 0] += 1
            return true
        }

        // Sort by frequency desc, then alphabetically for stability
        candidates = frequency.map { ($0.key, $0.value) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }

        return candidates.prefix(limit).map { $0.0 }
    }

    /// Returns a sentiment label for `text`: "positive", "negative", or "neutral".
    /// Uses `NLModel` for sentiment — available on iOS 13+, on-device, no network.
    static func sentiment(from text: String) -> String {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return "neutral" }
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = text
        let (tag, _) = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore)
        guard let scoreString = tag?.rawValue, let score = Double(scoreString) else { return "neutral" }
        if score > 0.1 { return "positive" }
        if score < -0.1 { return "negative" }
        return "neutral"
    }
}
