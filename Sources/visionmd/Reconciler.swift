import CoreGraphics
import Foundation

// MARK: - Mixed-source reconciler (Phase 2)
//
// Replaces Vision OCR text with PDF-layer text where the SourcePolicy accepts
// it. Structure (regions, ordering, element types) always stays with Vision;
// only the *text content* is swapped.

enum MixedSourceReconciler {

    /// Reconcile paragraph/heading text against the PDF layer's positioned runs.
    static func reconcile(
        _ elements: [DocElement],
        page: RasterizedPage,
        mode: TextLayerMode
    ) -> [DocElement] {
        guard mode != .off,
              let signals = page.signals,
              !page.positionedRuns.isEmpty else { return elements }

        // OCR character count for page classification.
        let ocrChars = elements.reduce(0) { acc, el in
            switch el {
            case .paragraph(let t, _, _), .heading(_, let t, _, _): return acc + t.count
            default: return acc
            }
        }
        let pageClass = SourcePolicy.classify(signals: signals, ocrCharCount: ocrChars)
        guard pageClass != .scanned else { return elements }

        let thresholds: SourcePolicy.Thresholds = (mode == .prefer) ? .prefer : .hybrid
        verbose("Page \(page.index + 1): class=\(pageClass.rawValue), \(page.positionedRuns.count) layer runs")

        return elements.map { el in
            switch el {
            case .paragraph(let ocrText, let region, let conf):
                let choice = choose(ocrText: ocrText, ocrConf: conf, region: region,
                                    page: page, pageClass: pageClass, thresholds: thresholds)
                switch choice {
                case .layer(let text):
                    return .paragraph(text: text, region: region, confidence: max(conf, 0.99))
                case .ocr, .ocrEscalate:
                    return el
                }

            case .heading(let level, let ocrText, let region, let conf):
                let choice = choose(ocrText: ocrText, ocrConf: conf, region: region,
                                    page: page, pageClass: pageClass, thresholds: thresholds)
                switch choice {
                case .layer(let text):
                    return .heading(level: level, text: text, region: region, confidence: max(conf, 0.99))
                case .ocr, .ocrEscalate:
                    return el
                }

            default:
                return el
            }
        }
    }

    // MARK: Region text assembly

    private static func choose(
        ocrText: String,
        ocrConf: Float,
        region: CGRect,
        page: RasterizedPage,
        pageClass: PageClass,
        thresholds: SourcePolicy.Thresholds
    ) -> TextChoice {
        let layerText = collectRunText(in: region, runs: page.positionedRuns)
        let choice = SourcePolicy.chooseText(
            ocr: ocrText,
            ocrConfidence: ocrConf,
            layerText: layerText,
            pageClass: pageClass,
            thresholds: thresholds
        )
        if case .ocr = choice, layerText != nil {
            verbose("Page \(page.index + 1): layer rejected for region \(region) — keeping OCR")
        }
        return choice
    }

    /// Collect layer runs whose center falls inside `region` (±0.5% tolerance),
    /// sort into reading order (top→bottom, left→right), join, and normalize.
    /// Returns nil when no runs match.
    static func collectRunText(in region: CGRect, runs: [PositionedTextRun]) -> String? {
        let tolerance: CGFloat = 0.005
        let expanded = region.insetBy(dx: -tolerance, dy: -tolerance)

        var matched = runs.filter { expanded.contains($0.rect.center) }
        guard !matched.isEmpty else { return nil }

        // Group into visual lines: runs whose vertical centers are within half
        // a line height of each other belong to the same line.
        matched.sort { a, b in
            if abs(a.rect.midY - b.rect.midY) > min(a.rect.height, b.rect.height) * 0.5 {
                return a.rect.midY < b.rect.midY
            }
            return a.rect.minX < b.rect.minX
        }

        var lines: [[PositionedTextRun]] = []
        for run in matched {
            if var last = lines.last,
               let anchor = last.first,
               abs(run.rect.midY - anchor.rect.midY) <= min(run.rect.height, anchor.rect.height) * 0.6 {
                last.append(run)
                lines[lines.count - 1] = last
            } else {
                lines.append([run])
            }
        }

        let text = lines
            .map { line in
                line.sorted { $0.rect.minX < $1.rect.minX }
                    .map(\.text)
                    .joined(separator: " ")
            }
            .joined(separator: "\n")

        let cleaned = TextCleaner.normalize(text)
        return cleaned.isEmpty ? nil : cleaned
    }
}
