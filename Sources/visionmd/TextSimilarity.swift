import Foundation

// MARK: - Text similarity for source-policy gating
//
// Bounded Levenshtein on case/whitespace-normalized prefixes. No dependencies.

enum TextSimilarity {

    /// Normalized similarity in [0,1] between the first `prefixLength` chars of
    /// both strings after case-folding and whitespace collapse.
    /// 1.0 = identical, 0.0 = nothing in common.
    static func similarity(_ a: String, _ b: String, prefixLength: Int = 200) -> Double {
        let na = Array(normalize(a).unicodeScalars.prefix(prefixLength))
        let nb = Array(normalize(b).unicodeScalars.prefix(prefixLength))
        if na.isEmpty && nb.isEmpty { return 1.0 }
        if na.isEmpty || nb.isEmpty { return 0.0 }
        let dist = levenshtein(na, nb)
        let maxLen = max(na.count, nb.count)
        return 1.0 - Double(dist) / Double(maxLen)
    }

    /// Case-fold and collapse all whitespace runs to single spaces.
    static func normalize(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Classic two-row Levenshtein distance over unicode scalars.
    private static func levenshtein(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = Swift.min(
                    prev[j] + 1,        // deletion
                    cur[j - 1] + 1,     // insertion
                    prev[j - 1] + cost  // substitution
                )
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
