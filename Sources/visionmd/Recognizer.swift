import CoreGraphics
import Foundation
import Vision

// MARK: - Stage 2: Vision document recognition
//
// ALL Vision framework API calls are isolated in this file.
// The rest of the pipeline uses only types from Model.swift.
//
// Verified against:
//   Vision.swiftmodule/arm64e-apple-macos.swiftinterface  (macOS 26.5 SDK)
//   RecognizeDocumentsRequest — returns [DocumentObservation]
//   DocumentObservation.Container — paragraphs / tables / lists / barcodes
//   Container.Text — .transcript, .boundingRegion, .lines (for confidence)
//   Container.Table — .rows [[Cell]], .columns [[Cell]], .boundingRegion
//   Container.Table.Cell — .rowRange, .columnRange, .content (Container)
//   Container.List — .items [List.Item], .boundingRegion
//   Container.List.Item — .itemString, .markerType
//   BarcodeObservation — .payloadString, .symbology, .boundingRegion
//   NormalizedRegion (= ContoursObservation.Contour) — .boundingBox: NormalizedRect
//   NormalizedRect — .cgRect: CGRect (Vision space: normalized, bottom-left origin)

enum Recognizer {

    // MARK: Main entry point (macOS 26 — full document recognition)

    static func recognize(
        _ image: CGImage,
        languages: [Locale.Language],
        level: RecognitionLevel       // maps to TextRecognitionOptions (no per-level API on docs request)
    ) async throws -> RawDocumentResult {
        var request = RecognizeDocumentsRequest()

        // Language configuration lives under textRecognitionOptions.
        if !languages.isEmpty {
            request.textRecognitionOptions.recognitionLanguages = languages
        }
        // RecognizeDocumentsRequest has no explicit recognitionLevel property;
        // it always uses the full recognition pipeline.

        let observations: [DocumentObservation] = try await request.perform(on: image)
        guard let obs = observations.first else {
            verbose("Vision returned no DocumentObservation")
            return .empty
        }
        return extractResult(from: obs.document)
    }

    // MARK: Vision result extraction
    //
    // Converts Vision types → RawDocumentResult so nothing else touches Vision types.

    private static func extractResult(from container: DocumentObservation.Container) -> RawDocumentResult {

        // Paragraphs
        var paragraphs: [RawParagraph] = []
        for para in container.paragraphs {
            let bbox = para.boundingRegion.boundingBox.cgRect  // NormalizedRect.cgRect → Vision space
            let conf = averageConfidence(para.lines)
            paragraphs.append(RawParagraph(
                text: para.transcript,
                visionBBox: bbox,
                confidence: conf,
                lineCount: para.lines.count
            ))
        }

        // Tables
        var tables: [RawTable] = []
        for vt in container.tables {
            let rowCount   = vt.rows.count
            let colCount   = vt.columns.count
            let bbox       = vt.boundingRegion.boundingBox.cgRect

            var rawCells: [RawTable.RawCell] = []
            for (_, row) in vt.rows.enumerated() {
                for cell in row {
                    let cellText = cell.content.text.transcript
                    let cellConf = averageConfidence(cell.content.paragraphs.flatMap(\.lines))
                    rawCells.append(RawTable.RawCell(
                        row:     cell.rowRange.lowerBound,
                        col:     cell.columnRange.lowerBound,
                        rowSpan: cell.rowRange.count,
                        colSpan: cell.columnRange.count,
                        text:    cellText,
                        confidence: cellConf
                    ))
                }
            }

            let aggConf: Float = rawCells.isEmpty ? 0.5 :
                rawCells.map(\.confidence).reduce(0, +) / Float(rawCells.count)

            tables.append(RawTable(
                rowCount:   rowCount,
                colCount:   colCount,
                cells:      rawCells,
                visionBBox: bbox,
                confidence: aggConf
            ))
        }

        // Lists
        var lists: [RawList] = []
        for vl in container.lists {
            let bbox = vl.boundingRegion.boundingBox.cgRect
            let ordered = isOrderedList(vl)
            let items = vl.items.map(\.itemString)
            lists.append(RawList(ordered: ordered, items: items, visionBBox: bbox, confidence: 0.9))
        }

        // Barcodes
        var barcodes: [RawBarcode] = []
        for bc in container.barcodes {
            let bbox    = bc.boundingRegion.boundingBox.cgRect
            let payload = bc.payloadString ?? ""
            let sym     = "\(bc.symbology)"   // BarcodeSymbology → e.g. "qr"
            barcodes.append(RawBarcode(payload: payload, symbology: sym, visionBBox: bbox))
        }

        return RawDocumentResult(paragraphs: paragraphs, tables: tables, lists: lists, barcodes: barcodes)
    }

    // MARK: Helpers

    /// Average confidence from an array of RecognizedTextObservation (text lines).
    private static func averageConfidence(_ lines: [RecognizedTextObservation]) -> Float {
        guard !lines.isEmpty else { return 0.8 }   // default when no lines reported
        return lines.map(\.confidence).reduce(0, +) / Float(lines.count)
    }

    /// Determine if a list is ordered based on the marker type of its first item.
    private static func isOrderedList(_ list: DocumentObservation.Container.List) -> Bool {
        guard let marker = list.items.first?.markerType else { return false }
        switch marker {
        case .decimal, .decorativeDecimal, .compositeDecimal,
             .lowercaseLatin, .uppercaseLatin:
            return true
        case .bullet, .hyphen:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: macOS 15 fallback (text-only, no document structure)
    //
    // Use when the package minimum is lowered to .macOS(.v15) and the binary
    // runs on macOS 15. Call recognizeTextOnly() from Pipeline.process() inside
    // an `if #available(macOS 26, *) { ... } else { ... }` block.

    static func recognizeTextOnly(
        _ image: CGImage,
        languages: [Locale.Language],
        level: RecognitionLevel
    ) async throws -> RawDocumentResult {
        var request = RecognizeTextRequest()
        if !languages.isEmpty {
            request.recognitionLanguages = languages
        }
        request.recognitionLevel = (level == .fast) ? .fast : .accurate

        let observations: [RecognizedTextObservation] = try await request.perform(on: image)

        let paragraphs: [RawParagraph] = observations.compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            // RecognizedTextObservation.boundingBox: NormalizedRect (from BoundingBoxProviding)
            let bbox = obs.boundingBox.cgRect   // Vision space (bottom-left, normalized)
            return RawParagraph(text: top.string, visionBBox: bbox, confidence: Float(top.confidence), lineCount: 1)
        }
        return RawDocumentResult(paragraphs: paragraphs, tables: [], lists: [], barcodes: [])
    }
}
