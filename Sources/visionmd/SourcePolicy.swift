import CoreGraphics
import Foundation

// MARK: - Source-selection policy (design core)
//
// ALL routing decisions between the PDF text layer and Vision OCR live here as
// pure functions over precomputed signals. Nothing else in the pipeline decides
// "layer vs OCR" on its own. Same inputs → same route → same output.
//
// See PLAN.md "The source-selection policy" for the spec table.

enum TextChoice: Equatable, Sendable {
    case layer(String)   // use this PDF-layer text
    case ocr             // keep the Vision transcript
    case ocrEscalate     // keep OCR but flag for re-OCR in the sidecar
}

enum SourcePolicy {

    // MARK: Page classification

    /// Classify a page from its static signals plus the OCR character count
    /// (available at reconcile time).
    static func classify(signals: PageSignals, ocrCharCount: Int) -> PageClass {
        // No usable layer → OCR only.
        guard signals.hasTextLayer, signals.garbleRatio < 0.1 else { return .scanned }

        // A scan that was previously OCR'd: its layer is someone else's OCR.
        if signals.fullPageImage { return .scannedWithOCRLayer }

        guard signals.garbleRatio < 0.05 else { return .scanned }

        // Layer covers < 60% of what Vision recognized → partially rasterized page.
        if ocrCharCount > 0 {
            let coverage = Double(signals.layerCharCount) / Double(ocrCharCount)
            if coverage < 0.6 { return .mixed }
        }
        return .digital
    }

    // MARK: Region-level text choice

    /// Acceptance thresholds vary by --text-layer mode.
    struct Thresholds: Sendable {
        let maxLengthDeviation: Double   // |len(layer)-len(ocr)| / max(len(ocr),1)
        let minSimilarity: Double        // normalized Levenshtein similarity
        static let hybrid = Thresholds(maxLengthDeviation: 0.4, minSimilarity: 0.7)
        static let prefer = Thresholds(maxLengthDeviation: 0.6, minSimilarity: 0.5)
    }

    /// Decide the text source for one region.
    ///
    /// - layerText: candidate text joined from positioned runs inside the region
    ///   (nil/empty = no runs found → the region is a rasterized graphic).
    /// - digitDense: > 30% digits in either candidate (table cells, amounts).
    static func chooseText(
        ocr: String,
        ocrConfidence: Float,
        layerText: String?,
        pageClass: PageClass,
        thresholds: Thresholds = .hybrid
    ) -> TextChoice {
        // Rule: scanned pages never consult the layer.
        guard pageClass != .scanned else { return .ocr }

        // Rule 1: no runs found → OCR (rasterized graphic with burned-in text).
        guard let layer = layerText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !layer.isEmpty else { return .ocr }

        // Some PDFs encode word gaps positionally with no space glyphs — the
        // layer then reads "RELATEDDOCUMENTS". Similarity ignores whitespace,
        // so guard explicitly: OCR sees the visual gaps; if the layer has far
        // fewer spaces, its extraction is space-deficient → keep OCR.
        if isSpaceDeficient(layer: layer, ocr: ocr) { return .ocr }

        let digitDense = isDigitDense(ocr) || isDigitDense(layer)
        let sim = TextSimilarity.similarity(layer, ocr)

        // Digit-dense regions: a silent digit swap is worse than flagged OCR.
        // Tightened gate regardless of page class or mode.
        if digitDense {
            if sim >= 0.85 { return .layer(layer) }
            return ocrConfidence < 0.5 ? .ocrEscalate : .ocr
        }

        // scannedWithOCRLayer: prefer OCR unless the layer agrees strongly
        // (then take the layer — it may carry better Unicode).
        if pageClass == .scannedWithOCRLayer {
            return sim >= 0.85 ? .layer(layer) : .ocr
        }

        // digital / mixed: accept layer on length agreement OR similarity.
        let lenDev = Double(abs(layer.count - ocr.count)) / Double(max(ocr.count, 1))
        if lenDev <= thresholds.maxLengthDeviation || sim >= thresholds.minSimilarity {
            return .layer(layer)
        }
        return .ocr
    }

    /// Layer text with less than half the OCR's word gaps → the PDF encodes
    /// spacing positionally and PDFKit dropped it ("RELATEDDOCUMENTS").
    static func isSpaceDeficient(layer: String, ocr: String) -> Bool {
        let ocrSpaces = ocr.filter { $0 == " " }.count
        guard ocrSpaces >= 2 else { return false }
        let layerSpaces = layer.filter { $0 == " " }.count
        return Double(layerSpaces) < Double(ocrSpaces) * 0.7
    }

    /// > 30% digits → treat as digit-dense (amounts, IDs, table cells).
    static func isDigitDense(_ s: String) -> Bool {
        let scalars = s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard !scalars.isEmpty else { return false }
        let digits = scalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        return Double(digits) / Double(scalars.count) > 0.3
    }
}
