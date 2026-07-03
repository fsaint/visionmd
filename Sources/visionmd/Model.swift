import CoreGraphics
import Foundation

// MARK: - Version

/// Single source of truth for the tool version (CLI --version, front matter,
/// sidecar `tool` field).
enum VisionMDVersion {
    static let string = "0.1"
}

// MARK: - Pipeline model types
// All Vision-specific types are converted into these before leaving Recognizer.swift.

enum DocElement: Sendable {
    case heading(level: Int, text: String, region: CGRect, confidence: Float)
    case paragraph(text: String, region: CGRect, confidence: Float)
    case list(ordered: Bool, items: [String], region: CGRect, confidence: Float)
    case table(TableModel, region: CGRect, confidence: Float)
    case figure(assetRelPath: String, region: CGRect, caption: String?)
    case barcode(payload: String, symbology: String, region: CGRect)

    /// Region in top-left normalized page space (see Geometry.swift).
    var region: CGRect {
        switch self {
        case .heading(_, _, let r, _): r
        case .paragraph(_, let r, _): r
        case .list(_, _, let r, _): r
        case .table(_, let r, _): r
        case .figure(_, let r, _): r
        case .barcode(_, _, let r): r
        }
    }

    var confidence: Float {
        switch self {
        case .heading(_, _, _, let c): c
        case .paragraph(_, _, let c): c
        case .list(_, _, _, let c): c
        case .table(_, _, let c): c
        case .figure: 1.0
        case .barcode: 1.0
        }
    }

    /// True for elements whose content is text-like (not a pure graphic).
    var isTextual: Bool {
        switch self {
        case .heading, .paragraph, .list, .table, .barcode: true
        case .figure: false
        }
    }
}

// MARK: -

struct TableModel: Sendable {
    let rowCount: Int
    let colCount: Int
    let cells: [Cell]
    let confidence: Float
    /// False when row 0 is data, not a header (TableRefiner.detectHeader).
    var headerDetected: Bool = true

    struct Cell: Sendable {
        let row: Int
        let col: Int
        let rowSpan: Int
        let colSpan: Int
        let text: String
        let confidence: Float
        /// Cell rect in internal-normalized (top-left) space; nil when Vision
        /// provided no per-cell geometry.
        var region: CGRect? = nil
        /// True when the source policy rejected the layer text AND OCR
        /// confidence was low — flag for re-OCR in the sidecar.
        var escalated: Bool = false
    }

    var hasMerges: Bool {
        cells.contains { $0.rowSpan > 1 || $0.colSpan > 1 }
    }

    /// [row, col] pairs of cells flagged for re-OCR.
    var escalatedCells: [[Int]] {
        cells.filter(\.escalated).map { [$0.row, $0.col] }
    }

    var hasEscalatedCells: Bool {
        cells.contains(where: \.escalated)
    }

    /// Returns a dense row-major 2-D grid filled with cell text.
    /// Merged cells populate only their top-left grid slot.
    func denseGrid() -> [[String]] {
        var grid = Array(repeating: Array(repeating: "", count: colCount), count: rowCount)
        for cell in cells {
            let r = cell.row, c = cell.col
            guard r >= 0, r < rowCount, c >= 0, c < colCount else { continue }
            grid[r][c] = cell.text
        }
        return grid
    }
}

// MARK: -

struct RasterizedPage: Sendable {
    let index: Int          // 0-based
    let image: CGImage
    let pixelSize: CGSize   // width × height in pixels at chosen DPI
    let pointSize: CGSize   // PDF mediaBox in 72-dpi point units
    let dpi: CGFloat
    /// Text extracted from the PDF text layer (nil for image inputs or when unavailable).
    /// Empty/garbled strings are treated as absent.
    let pdfTextLayer: String?
    /// Font metadata extracted from PDFPage.attributedString.
    /// nil for image inputs and scanned PDFs (no readable text layer).
    let fontInfo: PDFPageFontInfo?
    /// Positioned text runs from the PDF layer, rects in internal-normalized
    /// (top-left) space. Empty for image inputs and scanned PDFs.
    var positionedRuns: [PositionedTextRun] = []
    /// Static page signals for source-policy classification (nil for images).
    var signals: PageSignals? = nil
}

/// A text run from the PDF layer with its position on the page.
/// One run per visual line (font runs spanning lines are split).
struct PositionedTextRun: Sendable {
    let text: String
    /// Internal-normalized rect (top-left origin, [0,1]).
    let rect: CGRect
    let fontSize: CGFloat
    let fontName: String
    let isBold: Bool
    let isItalic: Bool
}

/// Static per-page signals computed during Stage 1 (all PDFKit access up front).
struct PageSignals: Sendable {
    let hasTextLayer: Bool      // usable (non-garbled) layer present
    let garbleRatio: CGFloat    // U+FFFD + C0 controls (excl. \n\r\t) / total
    let layerCharCount: Int     // usable layer character count
    let fullPageImage: Bool     // an image XObject big enough to cover the page
    let hasFontInfo: Bool       // attributedString produced usable font runs
}

/// How a page is served by the source-selection policy.
enum PageClass: String, Sendable {
    case digital                // text from PDF layer per-region; OCR fills gaps
    case scannedWithOCRLayer    // someone else's OCR in the layer — trust less
    case scanned                // OCR only
    case mixed                  // usable layer covering only part of the page
}

// MARK: - PDF structural types

/// Font metadata for a contiguous text run from PDFPage.attributedString.
struct PDFTextRun: Sendable {
    let text: String
    let fontSize: CGFloat       // NSFont.pointSize
    let fontName: String        // PostScript name (e.g. "Helvetica-Bold")
    let isBold: Bool
    let isItalic: Bool
}

/// Aggregated font info for a PDF page.
struct PDFPageFontInfo: Sendable {
    let runs: [PDFTextRun]
    let bodyFontSize: CGFloat   // weighted median — the "normal" text size
}

// MARK: -

struct PageResult: Sendable {
    let index: Int
    let pixelSize: CGSize
    let elements: [DocElement]

    var meanConfidence: Float {
        let scores = elements.map(\.confidence).filter { $0 > 0 }
        guard !scores.isEmpty else { return 1.0 }
        return scores.reduce(0, +) / Float(scores.count)
    }
}

// MARK: - Raw types from Recognizer (Vision bridge output)

struct RawDocumentResult: Sendable {
    var paragraphs: [RawParagraph]
    var tables: [RawTable]
    var lists: [RawList]
    var barcodes: [RawBarcode]

    static let empty = RawDocumentResult(paragraphs: [], tables: [], lists: [], barcodes: [])
}

struct RawParagraph: Sendable {
    let text: String
    /// CGRect in Vision coordinate space: normalized [0,1]×[0,1], origin bottom-left.
    let visionBBox: CGRect
    let confidence: Float
    /// Number of visual lines within the paragraph (from Vision Container.Text.lines.count).
    /// Used for heading inference; Vision transcripts don't contain embedded newlines.
    let lineCount: Int
}

struct RawTable: Sendable {
    let rowCount: Int
    let colCount: Int
    let cells: [RawCell]
    let visionBBox: CGRect
    let confidence: Float

    struct RawCell: Sendable {
        let row: Int
        let col: Int
        let rowSpan: Int
        let colSpan: Int
        let text: String
        let confidence: Float
        /// Cell content rect in Vision space (page-normalized, bottom-left
        /// origin — verified: cell.content.boundingRegion is page-relative,
        /// not table-local). nil when unavailable.
        var visionBBox: CGRect? = nil
    }
}

struct RawList: Sendable {
    let ordered: Bool
    let items: [String]
    let visionBBox: CGRect
    let confidence: Float
}

struct RawBarcode: Sendable {
    let payload: String
    let symbology: String
    let visionBBox: CGRect
}

// MARK: - Errors

enum VisionMDError: Error, CustomStringConvertible {
    case badInput(String)
    case unsupportedOS(String)
    case noDocument
    case pageOutOfRange(Int)
    case imageWriteFailed(URL)
    case rasterizationFailed(Int)

    var description: String {
        switch self {
        case .badInput(let s):          "Bad input: \(s)"
        case .unsupportedOS(let s):     s
        case .noDocument:               "Vision returned no document observation"
        case .pageOutOfRange(let n):    "Page \(n) is out of range"
        case .imageWriteFailed(let u):  "Failed to write image to \(u.path)"
        case .rasterizationFailed(let n): "Failed to rasterize page \(n)"
        }
    }
}

// MARK: - CLI option enums

enum RecognitionLevel: String, Sendable, CaseIterable {
    case fast, accurate
}

enum TextLayerMode: String, Sendable, CaseIterable {
    case off, prefer, hybrid
}

enum TableMode: String, Sendable, CaseIterable {
    case native, off
}

enum FigureMode: String, Sendable, CaseIterable {
    case crop, off
}

// MARK: - Page range

struct PageRange: Sendable {
    private let segments: [Segment]
    private enum Segment: Sendable {
        case single(Int)
        case closed(Int, Int)   // both inclusive, 1-indexed
        case from(Int)          // n to ∞
        case to(Int)            // 1 to n
    }

    /// Parse "1-5,8,11-" (1-indexed). Returns nil on bad input.
    init?(string: String) {
        var segs: [Segment] = []
        for part in string.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if part.contains("-") {
                let sub = part.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                let lhs = sub[0].isEmpty ? nil : Int(sub[0])
                let rhs = sub.count > 1 ? (sub[1].isEmpty ? nil : Int(sub[1])) : nil
                switch (lhs, rhs) {
                case (.some(let a), .some(let b)) where a <= b: segs.append(.closed(a, b))
                case (.some(let a), .none):                      segs.append(.from(a))
                case (.none, .some(let b)):                      segs.append(.to(b))
                default: return nil
                }
            } else if let n = Int(part) {
                segs.append(.single(n))
            } else {
                return nil
            }
        }
        guard !segs.isEmpty else { return nil }
        self.segments = segs
    }

    func contains(pageNumber: Int) -> Bool {
        segments.contains {
            switch $0 {
            case .single(let n):    pageNumber == n
            case .closed(let a, let b): pageNumber >= a && pageNumber <= b
            case .from(let a):      pageNumber >= a
            case .to(let b):        pageNumber <= b
            }
        }
    }
}
