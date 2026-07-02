import AppKit
import Foundation
import PDFKit

// MARK: - Stage 1b: PDF structural metadata extraction
//
// Extracts font metadata from digital PDFs using PDFKit's attributedString.
// Returns nil for scanned PDFs (no readable text layer) or image inputs.
// Isolates all AppKit font API calls (cf. Recognizer.swift for Vision isolation).

enum PDFStructureExtractor {

    /// Extract font metadata from a PDFPage's attributedString.
    /// Returns nil if the page has no attributedString or no usable font runs.
    static func extractFontInfo(from pdfPage: PDFPage) -> PDFPageFontInfo? {
        guard let attrStr = pdfPage.attributedString, attrStr.length > 0 else { return nil }

        var runs: [PDFTextRun] = []
        let nsStr = attrStr.string as NSString
        let fullRange = NSRange(location: 0, length: attrStr.length)

        attrStr.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            guard let font = value as? NSFont, range.length > 0 else { return }
            let text = nsStr.substring(with: range)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let traits = font.fontDescriptor.symbolicTraits
            runs.append(PDFTextRun(
                text: text,
                fontSize: font.pointSize,
                fontName: font.fontName,
                isBold: traits.contains(.bold),
                isItalic: traits.contains(.italic)
            ))
        }

        guard !runs.isEmpty else { return nil }
        return PDFPageFontInfo(runs: runs, bodyFontSize: weightedMedianFontSize(runs: runs))
    }

    /// Compute the weighted median font size, weighted by character count.
    /// Example: 80% of characters at 12pt + 20% at 24pt → bodyFontSize = 12pt.
    static func weightedMedianFontSize(runs: [PDFTextRun]) -> CGFloat {
        let totalChars = runs.reduce(0) { $0 + $1.text.count }
        guard totalChars > 0 else { return 12.0 }
        let sorted = runs.sorted { $0.fontSize < $1.fontSize }
        let half = (totalChars + 1) / 2
        var cumulative = 0
        for run in sorted {
            cumulative += run.text.count
            if cumulative >= half { return run.fontSize }
        }
        return sorted.last?.fontSize ?? 12.0
    }
}
