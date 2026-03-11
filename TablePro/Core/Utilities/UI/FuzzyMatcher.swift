//
//  FuzzyMatcher.swift
//  TablePro
//
//  Standalone fuzzy matching utility for quick switcher search
//

import Foundation

/// Namespace for fuzzy string matching operations
enum FuzzyMatcher {
    /// Score a candidate string against a search query.
    /// Returns 0 for no match, higher values indicate better matches.
    /// Empty query returns 1 (everything matches).
    static func score(query: String, candidate: String) -> Int {
        let queryNS = query as NSString
        let candidateNS = candidate as NSString
        let queryLen = queryNS.length
        let candidateLen = candidateNS.length

        if queryLen == 0 { return 1 }
        if candidateLen == 0 { return 0 }

        var score = 0
        var queryIndex = 0
        var consecutiveBonus = 0
        var firstMatchPosition = -1

        for candidateIndex in 0..<candidateLen {
            guard queryIndex < queryLen else { break }

            guard let queryScalar = UnicodeScalar(queryNS.character(at: queryIndex)),
                  let candidateScalar = UnicodeScalar(candidateNS.character(at: candidateIndex))
            else {
                consecutiveBonus = 0
                continue
            }

            let queryChar = Character(queryScalar)
            let candidateChar = Character(candidateScalar)

            guard queryChar.lowercased() == candidateChar.lowercased() else {
                consecutiveBonus = 0
                continue
            }

            // Base match score
            var matchScore = 1

            // Record first match position for position bonus
            if firstMatchPosition < 0 {
                firstMatchPosition = candidateIndex
            }

            // Consecutive match bonus (grows quadratically with each consecutive hit)
            consecutiveBonus += 1
            if consecutiveBonus > 1 {
                matchScore += consecutiveBonus * 4
            }

            // Word boundary bonus: after space, underscore, or camelCase transition
            if candidateIndex == 0 {
                matchScore += 10
            } else {
                guard let prevScalar = UnicodeScalar(candidateNS.character(at: candidateIndex - 1)) else {
                    score += matchScore
                    queryIndex += 1
                    continue
                }
                let prevChar = Character(prevScalar)
                if prevChar == " " || prevChar == "_" || prevChar == "." || prevChar == "-" {
                    matchScore += 8
                    consecutiveBonus = 1
                } else if prevChar.isLowercase && candidateChar.isUppercase {
                    // camelCase boundary
                    matchScore += 6
                    consecutiveBonus = 1
                }
            }

            // Exact case match bonus
            if queryChar == candidateChar {
                matchScore += 1
            }

            score += matchScore
            queryIndex += 1
        }

        // All query characters must be matched
        guard queryIndex == queryLen else { return 0 }

        // Position bonus: earlier matches score higher
        if firstMatchPosition >= 0 {
            let positionBonus = max(0, 20 - firstMatchPosition * 2)
            score += positionBonus
        }

        // Length similarity bonus: prefer shorter candidates (closer to query length)
        let lengthRatio = Double(queryLen) / Double(candidateLen)
        score += Int(lengthRatio * 10)

        return score
    }
}
