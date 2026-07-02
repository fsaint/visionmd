import Foundation

// MARK: - Text normalization
//
// Applied to ALL text at render time regardless of source (layer or OCR),
// so both sources produce identical bytes for identical content.

enum TextCleaner {

    private static let ligatures: [(String, String)] = [
        ("\u{FB00}", "ff"), ("\u{FB01}", "fi"), ("\u{FB02}", "fl"),
        ("\u{FB03}", "ffi"), ("\u{FB04}", "ffl"),
    ]

    /// Unicode NFC + ligature expansion + soft-hyphen removal + space-run collapse.
    /// Newlines are preserved (paragraph collapse happens at render time).
    static func normalize(_ s: String) -> String {
        var out = s.precomposedStringWithCanonicalMapping

        for (lig, replacement) in ligatures {
            out = out.replacingOccurrences(of: lig, with: replacement)
        }

        // Soft hyphen (U+00AD) is an invisible hint — drop it.
        out = out.replacingOccurrences(of: "\u{00AD}", with: "")

        // Non-breaking space → plain space, then collapse space/tab runs.
        out = out.replacingOccurrences(of: "\u{00A0}", with: " ")
        while out.contains("  ") {
            out = out.replacingOccurrences(of: "  ", with: " ")
        }
        out = out.replacingOccurrences(of: "\t", with: " ")

        return out.trimmingCharacters(in: .whitespaces)
    }
}
