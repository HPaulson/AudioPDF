import Foundation

public enum SynthesisTextChunker {
    public static func chunks(
        from text: String,
        maximumCharacters: Int = 400,
        combineSentences: Bool = false
    ) -> [String] {
        precondition(maximumCharacters > 0)
        let normalized = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty else { return [] }

        var sentences: [String] = []
        normalized.enumerateSubstrings(
            in: normalized.startIndex..<normalized.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, range, _, _ in
            let sentence = normalized[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
        }
        if sentences.isEmpty {
            sentences = [normalized]
        }

        var result: [String] = []
        var pending = ""
        for sentence in sentences {
            if combineSentences {
                let candidate = pending.isEmpty ? sentence : "\(pending) \(sentence)"
                if candidate.count <= maximumCharacters {
                    pending = candidate
                    continue
                }
                if !pending.isEmpty {
                    result.append(pending)
                    pending = ""
                }
            }
            append(sentence, maximumCharacters: maximumCharacters, to: &result)
        }
        if !pending.isEmpty {
            result.append(pending)
        }
        return result
    }

    private static func append(
        _ text: String,
        maximumCharacters: Int,
        to result: inout [String]
    ) {
        guard text.count > maximumCharacters else {
            result.append(text)
            return
        }

        var current = ""
        for word in text.split(separator: " ").map(String.init) {
            if word.count > maximumCharacters {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
                var remainder = word[...]
                while remainder.count > maximumCharacters {
                    let end = remainder.index(remainder.startIndex, offsetBy: maximumCharacters)
                    result.append(String(remainder[..<end]))
                    remainder = remainder[end...]
                }
                if !remainder.isEmpty {
                    current = String(remainder)
                }
                continue
            }

            let candidate = current.isEmpty ? word : "\(current) \(word)"
            if candidate.count <= maximumCharacters {
                current = candidate
            } else {
                result.append(current)
                current = word
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
    }
}
