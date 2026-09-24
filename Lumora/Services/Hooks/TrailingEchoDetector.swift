//
//  TrailingEchoDetector.swift
//  Lumora
//
//  Pure value type for trailing-echo detection. The known opencode v1.15.13
//  bug emits a trailing text (or text deltas) on a reasoning messageID whose
//  content equals the user prompt or reasoning content. The original substring
//  check (`t == p || p.contains(t) || t.contains(p)`) was too greedy:
//  "weather" + "The weather is sunny" would false-positive. This version uses
//  exact match + length-bounded Levenshtein similarity, no substring.
//

import Foundation

struct TrailingEchoDetector {
    let userPrompt: String
    let reasoningContent: String?

    func isEcho(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let prompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty && trimmed == prompt { return true }

        if let reasoning = reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reasoning.isEmpty && trimmed == reasoning { return true }

        if !prompt.isEmpty, abs(trimmed.count - prompt.count) <= 3, trimmed.count >= 5 {
            if levenshteinNormalized(trimmed.lowercased(), prompt.lowercased()) < 0.15 { return true }
        }

        if let reasoning = reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reasoning.isEmpty, abs(trimmed.count - reasoning.count) <= 3, trimmed.count >= 5 {
            if levenshteinNormalized(trimmed.lowercased(), reasoning.lowercased()) < 0.15 { return true }
        }

        return false
    }

    private func levenshteinNormalized(_ lhs: String, _ rhs: String) -> Double {
        let dist = levenshtein(lhs, rhs)
        let maxLen = max(lhs.count, rhs.count)
        return maxLen == 0 ? 0 : Double(dist) / Double(maxLen)
    }

    private func levenshtein(_ lhs: String, _ rhs: String) -> Int {
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)
        let lhsCount = lhsChars.count
        let rhsCount = rhsChars.count

        if lhsCount == 0 { return rhsCount }
        if rhsCount == 0 { return lhsCount }

        var prev = Array(0...rhsCount)
        var curr = [Int](repeating: 0, count: rhsCount + 1)

        for i in 1...lhsCount {
            curr[0] = i
            for j in 1...rhsCount {
                let cost = lhsChars[i - 1] == rhsChars[j - 1] ? 0 : 1
                curr[j] = min(min(
                    prev[j] + 1,
                    curr[j - 1] + 1),
                    prev[j - 1] + cost
                )
            }
            swap(&prev, &curr)
        }

        return prev[rhsCount]
    }
}
