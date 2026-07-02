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

    // MARK: Positioned runs (Phase 2 — mixed-source backbone)

    /// Extract positioned text runs: one run per (font run × visual line), with
    /// rects converted to internal-normalized (top-left) space.
    /// All PDFKit access happens here, up front — results are Sendable.
    static func extractPositionedRuns(from pdfPage: PDFPage) -> [PositionedTextRun] {
        guard let attrStr = pdfPage.attributedString, attrStr.length > 0 else { return [] }
        let mediaBox = pdfPage.bounds(for: .mediaBox)
        guard mediaBox.width > 0, mediaBox.height > 0 else { return [] }

        var runs: [PositionedTextRun] = []
        let fullRange = NSRange(location: 0, length: attrStr.length)

        attrStr.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            guard let font = value as? NSFont, range.length > 0 else { return }
            guard let selection = pdfPage.selection(for: range) else { return }
            let traits = font.fontDescriptor.symbolicTraits

            // Split font runs that span multiple visual lines.
            for line in selection.selectionsByLine() {
                guard let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { continue }
                let bounds = line.bounds(for: pdfPage)
                guard bounds.width > 0, bounds.height > 0 else { continue }

                // mediaBox points (bottom-left origin) → internal-normalized (top-left).
                let normX = (bounds.minX - mediaBox.minX) / mediaBox.width
                let normW = bounds.width / mediaBox.width
                let normH = bounds.height / mediaBox.height
                let normY = 1.0 - (bounds.maxY - mediaBox.minY) / mediaBox.height

                runs.append(PositionedTextRun(
                    text: text,
                    rect: CGRect(x: normX, y: normY, width: normW, height: normH),
                    fontSize: font.pointSize,
                    fontName: font.fontName,
                    isBold: traits.contains(.bold),
                    isItalic: traits.contains(.italic)
                ))
            }
        }
        return runs
    }

    // MARK: Page signals

    /// True when the page's resources contain an image XObject large enough to
    /// cover the page (≈ a scan). Pixel dimensions are compared against the
    /// mediaBox at 100 DPI — a real scan is 150–600 DPI, so this is generous.
    static func hasFullPageImage(_ pdfPage: PDFPage) -> Bool {
        guard let cgPage = pdfPage.pageRef,
              let dict = cgPage.dictionary else { return false }
        let mediaBox = pdfPage.bounds(for: .mediaBox)
        let minW = mediaBox.width / 72.0 * 100.0
        let minH = mediaBox.height / 72.0 * 100.0

        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources),
              let res = resources else { return false }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(res, "XObject", &xobjects),
              let xo = xobjects else { return false }

        // Iterate XObject entries looking for a page-sized image.
        final class Box { var found = false; var minW: CGFloat = 0; var minH: CGFloat = 0 }
        let box = Box()
        box.minW = minW
        box.minH = minH
        let ptr = Unmanaged.passUnretained(box).toOpaque()

        CGPDFDictionaryApplyBlock(xo, { _, object, info in
            let box = Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue()
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let s = stream,
                  let sDict = CGPDFStreamGetDictionary(s) else { return true }
            var subtype: UnsafePointer<Int8>?
            guard CGPDFDictionaryGetName(sDict, "Subtype", &subtype),
                  let st = subtype, String(cString: st) == "Image" else { return true }
            var w: CGPDFInteger = 0, h: CGPDFInteger = 0
            CGPDFDictionaryGetInteger(sDict, "Width", &w)
            CGPDFDictionaryGetInteger(sDict, "Height", &h)
            if CGFloat(w) >= box.minW && CGFloat(h) >= box.minH {
                box.found = true
                return false   // stop iterating
            }
            return true
        }, ptr)

        return box.found
    }

    /// Compute static page signals for the source policy.
    static func extractSignals(from pdfPage: PDFPage, textLayer: String?, hasFontInfo: Bool) -> PageSignals {
        let raw = pdfPage.string ?? ""
        let garble = garbleRatio(raw)
        let usable = textLayer ?? ""
        return PageSignals(
            hasTextLayer: !usable.isEmpty,
            garbleRatio: garble,
            layerCharCount: usable.count,
            fullPageImage: hasFullPageImage(pdfPage),
            hasFontInfo: hasFontInfo
        )
    }

    /// U+FFFD + C0 controls (excluding \n\r\t) / total scalars.
    static func garbleRatio(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let whitespaceControls: Set<UInt32> = [0x09, 0x0A, 0x0D]
        let total = text.unicodeScalars.count
        let garbage = text.unicodeScalars.filter {
            $0.value == 0xFFFD || ($0.value < 32 && !whitespaceControls.contains($0.value))
        }.count
        return CGFloat(garbage) / CGFloat(total)
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
