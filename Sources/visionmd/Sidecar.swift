import CoreGraphics
import Foundation

// MARK: - Stage 6: Sidecar JSON (§10.3)
//
// Produces a machine-readable file that a downstream VLM router can consume
// to escalate low-confidence regions for re-OCR.

// MARK: - Codable model

struct SidecarDocument: Codable, Sendable {
    let source: String
    let tool: String
    let dpi: Int
    let pages: [SidecarPage]
}

struct SidecarPage: Codable, Sendable {
    let index: Int
    let pixelSize: [Int]            // [width, height]
    let elements: [SidecarElement]

    enum CodingKeys: String, CodingKey {
        case index
        case pixelSize = "pixel_size"
        case elements
    }
}

struct SidecarElement: Codable, Sendable {
    let id: String
    let type: String
    let bboxNorm: [Double]          // [minX, minY, maxX, maxY] top-left normalized
    let confidence: Double?
    let rows: Int?
    let cols: Int?
    let complex: Bool?
    let split: Bool?
    let mdAnchor: String?
    let asset: String?
    let escalate: Bool
    /// [row, col] pairs of table cells whose layer text was rejected at low
    /// OCR confidence (present only when non-empty).
    var escalatedCells: [[Int]]? = nil

    enum CodingKeys: String, CodingKey {
        case id, type
        case bboxNorm = "bbox_norm"
        case confidence, rows, cols, complex, split
        case mdAnchor = "md_anchor"
        case asset, escalate
        case escalatedCells = "escalated_cells"
    }
}

// MARK: - Builder

enum Sidecar {

    static func build(
        results: [PageResult],
        source: String,
        dpi: Double,
        minConfidence: Float
    ) -> SidecarDocument {
        let pages = results.sorted { $0.index < $1.index }.map { result in
            buildPage(result, minConfidence: minConfidence)
        }
        return SidecarDocument(
            source: source,
            tool: "visionmd/\(VisionMDVersion.string)",
            dpi: Int(dpi),
            pages: pages
        )
    }

    private static func buildPage(_ result: PageResult, minConfidence: Float) -> SidecarPage {
        var tableCount = 0
        var figureCount = 0
        var paraCount = 0

        let elements: [SidecarElement] = result.elements.compactMap { el in
            let r = el.region
            let bbox = [
                Double(r.minX), Double(r.minY),
                Double(r.maxX), Double(r.maxY)
            ]
            let pageIdx = result.index + 1

            switch el {
            case .table(let model, _, let conf):
                tableCount += 1
                let id = "t_p\(pageIdx)_\(tableCount)"
                let isComplex = model.hasMerges
                let escalate = conf < minConfidence || isComplex || model.hasEscalatedCells
                let anchor = isComplex ? "<!-- visionmd:complex-table id=\(id) -->" : nil
                return SidecarElement(
                    id: id,
                    type: "table",
                    bboxNorm: bbox,
                    confidence: Double(conf),
                    rows: model.rowCount,
                    cols: model.colCount,
                    complex: isComplex,
                    split: nil,
                    mdAnchor: anchor,
                    asset: nil,
                    escalate: escalate,
                    escalatedCells: model.hasEscalatedCells ? model.escalatedCells : nil
                )

            case .figure(let path, _, _):
                figureCount += 1
                let id = "f_p\(pageIdx)_\(figureCount)"
                return SidecarElement(
                    id: id,
                    type: "figure",
                    bboxNorm: bbox,
                    confidence: nil,
                    rows: nil, cols: nil, complex: nil, split: nil,
                    mdAnchor: nil,
                    asset: path,
                    escalate: false
                )

            case .paragraph(_, _, let conf):
                guard conf < minConfidence else { return nil }
                paraCount += 1
                let id = "par_p\(pageIdx)_\(paraCount)"
                return SidecarElement(
                    id: id,
                    type: "paragraph",
                    bboxNorm: bbox,
                    confidence: Double(conf),
                    rows: nil, cols: nil, complex: nil, split: nil,
                    mdAnchor: nil, asset: nil,
                    escalate: true
                )

            case .heading(_, _, _, let conf):
                guard conf < minConfidence else { return nil }
                paraCount += 1
                let id = "hd_p\(pageIdx)_\(paraCount)"
                return SidecarElement(
                    id: id,
                    type: "heading",
                    bboxNorm: bbox,
                    confidence: Double(conf),
                    rows: nil, cols: nil, complex: nil, split: nil,
                    mdAnchor: nil, asset: nil,
                    escalate: true
                )

            case .list(_, _, _, let conf):
                guard conf < minConfidence else { return nil }
                paraCount += 1
                let id = "lst_p\(pageIdx)_\(paraCount)"
                return SidecarElement(
                    id: id,
                    type: "list",
                    bboxNorm: bbox,
                    confidence: Double(conf),
                    rows: nil, cols: nil, complex: nil, split: nil,
                    mdAnchor: nil, asset: nil,
                    escalate: true
                )

            case .barcode:
                return nil   // Barcodes always high-confidence; not escalated.
            }
        }

        return SidecarPage(
            index: result.index,
            pixelSize: [Int(result.pixelSize.width), Int(result.pixelSize.height)],
            elements: elements
        )
    }

    // MARK: Writing

    static func write(_ doc: SidecarDocument, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(doc)
        try data.write(to: url, options: .atomic)
        log("Sidecar written → \(url.path)")
    }
}
