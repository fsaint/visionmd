import CoreGraphics
import Foundation

// MARK: - Stage 3: Layout and reading-order resolution
//
// Input:  RawDocumentResult (Vision bounding boxes in Vision space)
// Output: [DocElement] in reading order, regions in internal (top-left normalized) space

enum LayoutResolver {

    // MARK: Public entry

    /// Convert raw Vision output into ordered DocElements using the page's geometry.
    static func resolve(
        _ raw: RawDocumentResult,
        page: RasterizedPage,
        minConfidence: Float
    ) -> [DocElement] {
        // Convert all bboxes from Vision space to internal (top-left, normalized).
        var elements: [DocElement] = []

        // Tables override their region; track them first so text inside is dropped later.
        var tableRects: [CGRect] = []

        for rt in raw.tables {
            let region = Geometry.visionToInternal(rt.visionBBox)
            let tm = TableModel(
                rowCount: rt.rowCount,
                colCount: rt.colCount,
                cells: rt.cells.map {
                    TableModel.Cell(
                        row: $0.row, col: $0.col,
                        rowSpan: $0.rowSpan, colSpan: $0.colSpan,
                        text: $0.text, confidence: $0.confidence
                    )
                },
                confidence: rt.confidence
            )
            elements.append(.table(tm, region: region, confidence: rt.confidence))
            tableRects.append(region)
        }

        // Paragraphs — skip any fully inside a table region.
        for rp in raw.paragraphs {
            let region = Geometry.visionToInternal(rp.visionBBox)
            guard !isInsideTable(region, tables: tableRects) else { continue }
            let elem = classifyParagraph(text: rp.text, region: region, confidence: rp.confidence, lineCount: rp.lineCount, page: page)
            elements.append(elem)
        }

        // Lists
        for rl in raw.lists {
            let region = Geometry.visionToInternal(rl.visionBBox)
            guard !isInsideTable(region, tables: tableRects) else { continue }
            elements.append(.list(ordered: rl.ordered, items: rl.items, region: region, confidence: rl.confidence))
        }

        // Barcodes
        for rb in raw.barcodes {
            let region = Geometry.visionToInternal(rb.visionBBox)
            elements.append(.barcode(payload: rb.payload, symbology: rb.symbology, region: region))
        }

        return order(elements, page: page)
    }

    // MARK: Reading order

    /// Sort elements into newspaper reading order: detect columns, then sort by (col, Y, X).
    static func order(_ elements: [DocElement], page: RasterizedPage) -> [DocElement] {
        guard !elements.isEmpty else { return elements }

        let fullWidthThreshold: CGFloat = 0.8
        let columns = detectColumns(elements)

        // Assign each element a column index (-1 for full-width breaks).
        struct Ranked {
            let element: DocElement
            let col: Int
            let y: CGFloat
            let x: CGFloat
        }

        var ranked: [Ranked] = elements.map { el in
            let r = el.region
            if r.width >= fullWidthThreshold {
                return Ranked(element: el, col: -1, y: r.minY, x: r.minX)
            }
            let cx = r.midX
            let col = columns.firstIndex { $0.contains(cx) } ?? 0
            return Ranked(element: el, col: col, y: r.minY, x: r.minX)
        }

        ranked.sort {
            if $0.col != $1.col { return $0.col < $1.col }
            if abs($0.y - $1.y) > 0.005 { return $0.y < $1.y }
            return $0.x < $1.x
        }

        return ranked.map(\.element)
    }

    // MARK: Column detection

    /// Returns column x-bands as closed ranges [minX, maxX] in internal-normalized space.
    ///
    /// Strategy: project element x-extents (minX…maxX) onto the page axis, merge
    /// overlapping/touching extents, then only treat the result as multi-column if the
    /// gap between merged zones is at least 10% of page width.  This prevents centered
    /// headings + left-aligned body text from being mis-classified as two columns.
    private static func detectColumns(_ elements: [DocElement]) -> [ClosedRange<CGFloat>] {
        let textElements = elements.filter { $0.isTextual && $0.region.width < 0.75 }
        guard !textElements.isEmpty else { return [0...1] }

        // Build and sort (minX, maxX) intervals.
        var intervals = textElements.map { ($0.region.minX, $0.region.maxX) }
        intervals.sort { $0.0 < $1.0 }

        // Merge overlapping / nearly-touching intervals (allow 5% gap within a zone).
        var merged: [(CGFloat, CGFloat)] = []
        var curLo = intervals[0].0
        var curHi = intervals[0].1
        for (lo, hi) in intervals.dropFirst() {
            if lo <= curHi + 0.05 {
                curHi = max(curHi, hi)
            } else {
                merged.append((curLo, curHi))
                curLo = lo
                curHi = hi
            }
        }
        merged.append((curLo, curHi))

        // Require a genuine gap (≥ 10% of page width) between zones to call it multi-column.
        let minGap: CGFloat = 0.10
        guard merged.count >= 2 else { return [0.0...1.0] }
        for i in 0..<(merged.count - 1) {
            if merged[i + 1].0 - merged[i].1 < minGap { return [0.0...1.0] }
        }
        return merged.map { $0.0...$0.1 }
    }

    // MARK: Heading inference

    private static func classifyParagraph(
        text: String,
        region: CGRect,
        confidence: Float,
        lineCount: Int,
        page: RasterizedPage
    ) -> DocElement {
        // Use precise font-size classification when PDF font metadata is available.
        if let fontInfo = page.fontInfo {
            return classifyByFontSize(text: text, region: region, confidence: confidence, fontInfo: fontInfo)
        }

        // Fallback: line-height heuristic for scanned PDFs and image inputs.
        let lineCount = max(1, lineCount)
        // Approximate line height in normalized units.
        let lineH = region.height / CGFloat(lineCount)

        // Body median: rough estimate (≈ 12pt / page height in points, normalized).
        let medianLineH: CGFloat = 12.0 / max(page.pointSize.height, 1)

        let ratio = medianLineH > 0 ? lineH / medianLineH : 1.0
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let charCount = trimmed.count
        let isShortLine = charCount > 0 && charCount < 80
        let isAllCaps = trimmed == trimmed.uppercased() && charCount > 2
        // "Label: value" patterns are form fields, not headings.
        let isFieldLabel = trimmed.contains(":") && trimmed.firstIndex(of: ":")
            .map { trimmed.distance(from: trimmed.startIndex, to: $0) < 40 } ?? false

        let ok = !isFieldLabel && !isNonHeadingContent(trimmed)
        let level: Int?
        if ok && ((ratio > 1.8 && isShortLine) || (ratio > 1.4 && isAllCaps)) {
            level = 1
        } else if ok && ratio > 1.4 && isShortLine {
            level = 2
        } else if ok && ratio > 1.15 && isShortLine {
            level = 3
        } else {
            level = nil
        }

        if let l = level {
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return .heading(level: l, text: cleaned, region: region, confidence: confidence)
        }
        return .paragraph(text: text, region: region, confidence: confidence)
    }

    /// Classify a paragraph using PDF font size information.
    /// Tighter thresholds than the heuristic because real font sizes are precise.
    static func classifyByFontSize(
        text: String,
        region: CGRect,
        confidence: Float,
        fontInfo: PDFPageFontInfo
    ) -> DocElement {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let charCount = trimmed.count
        let isShortLine = charCount > 0 && charCount < 80
        let isFieldLabel = trimmed.contains(":") &&
            (trimmed.firstIndex(of: ":").map { trimmed.distance(from: trimmed.startIndex, to: $0) < 40 } ?? false)

        let fontSize = dominantFontSize(for: trimmed, in: fontInfo) ?? fontInfo.bodyFontSize
        let ratio = fontInfo.bodyFontSize > 0 ? fontSize / fontInfo.bodyFontSize : 1.0
        let isAllCaps = trimmed == trimmed.uppercased() && charCount > 2

        let ok = !isFieldLabel && isShortLine && !isNonHeadingContent(trimmed)
        let level: Int?
        if ok {
            if ratio >= 1.6                   { level = 1 }
            else if ratio >= 1.3              { level = 2 }
            else if ratio >= 1.1              { level = 3 }
            else if ratio >= 1.0 && isAllCaps { level = 3 }  // all-caps section headers at body size
            else                              { level = nil }
        } else {
            level = nil
        }

        if let l = level {
            return .heading(level: l, text: trimmed, region: region, confidence: confidence)
        }
        return .paragraph(text: text, region: region, confidence: confidence)
    }

    /// Returns true when text is clearly not a heading — used by both the
    /// font-size path and the heuristic fallback.
    ///
    /// Blocks:
    ///  - Strings shorter than 6 characters (dates like "005", status like "TBD")
    ///  - Pure-numeric strings (dates, phone numbers, project numbers, amounts)
    ///  - Digit-heavy strings (>65% digits, < 20 chars — fax "F413.734.1881")
    static func isNonHeadingContent(_ text: String) -> Bool {
        let n = text.count
        guard n >= 6 else { return true }

        let letters = text.filter { $0.isLetter }
        let digits  = text.filter { $0.isNumber }

        // No letters + has at least one digit → numeric (date, phone, year, amount)
        if letters.isEmpty && !digits.isEmpty { return true }

        // Digit-heavy (>65%) + short → phone/fax number with a letter prefix
        if n < 20 && !digits.isEmpty &&
            Float(digits.count) / Float(n) > 0.65 { return true }

        return false
    }

    /// Find the dominant font size for `text` by matching against PDF runs.
    /// Returns nil if no matching runs are found.
    private static func dominantFontSize(for text: String, in fontInfo: PDFPageFontInfo) -> CGFloat? {
        let normalizedText = text.lowercased()
        var sizeWeights: [CGFloat: Int] = [:]

        for run in fontInfo.runs {
            let norm = run.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !norm.isEmpty else { continue }

            let overlap: Int
            if normalizedText.contains(norm) || norm.contains(normalizedText) {
                overlap = min(norm.count, normalizedText.count)
            } else {
                let runWords = Set(norm.components(separatedBy: .whitespaces).filter { $0.count > 2 })
                let textWords = Set(normalizedText.components(separatedBy: .whitespaces).filter { $0.count > 2 })
                overlap = runWords.intersection(textWords).reduce(0) { $0 + $1.count }
            }

            if overlap > 0 {
                sizeWeights[run.fontSize, default: 0] += overlap
            }
        }

        return sizeWeights.max(by: { $0.value < $1.value })?.key
    }

    // MARK: Helpers

    private static func isInsideTable(_ region: CGRect, tables: [CGRect]) -> Bool {
        tables.contains { Geometry.isContained(region, within: $0, threshold: 0.7) }
    }
}

// MARK: - Hybrid text-layer reconciler (§5.1)

enum HybridReconciler {

    /// Merge Vision elements with a PDF text layer.
    ///
    /// Strategy:
    ///  - Keep all Vision-detected tables and lists (structure information).
    ///  - For paragraphs: if the PDF text layer covers the same region with high
    ///    confidence, replace the Vision transcript with the PDFKit text.
    ///    (PDFKit text is crisper and correctly encoded; Vision gives better layout.)
    ///  - The PDFKit text is compared region-by-region; for v0.1 we use the full
    ///    page text as the paragraph text only when Vision found a single paragraph
    ///    on the page (simple case). Full reconciliation is deferred to v0.2.
    static func merge(
        _ elements: [DocElement],
        pdfTextLayer: String?
    ) -> [DocElement] {
        guard let pdfText = pdfTextLayer, !pdfText.isEmpty else { return elements }

        // Split PDFKit text into approximate paragraphs by double-newline.
        let pdfParas = pdfText
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Count how many Vision paragraphs we have.
        let visionParas = elements.filter {
            if case .paragraph = $0 { return true }
            if case .heading = $0   { return true }
            return false
        }

        // Simple reconciliation: if counts roughly match, zip by index.
        // Otherwise fall back to Vision transcript (reconciliation needs geometry).
        guard abs(visionParas.count - pdfParas.count) <= 2 else { return elements }

        var pdfIdx = 0
        return elements.map { el in
            switch el {
            case .paragraph(_, let region, let conf):
                guard pdfIdx < pdfParas.count else { return el }
                let text = pdfParas[pdfIdx]
                pdfIdx += 1
                return .paragraph(text: text, region: region, confidence: conf)
            case .heading(let lv, _, let region, let conf):
                guard pdfIdx < pdfParas.count else { return el }
                let text = pdfParas[pdfIdx]
                pdfIdx += 1
                return .heading(level: lv, text: text, region: region, confidence: conf)
            default:
                return el
            }
        }
    }
}
