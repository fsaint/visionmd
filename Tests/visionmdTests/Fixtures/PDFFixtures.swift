import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import visionmd

// MARK: - Synthetic PDF fixtures
//
// Fixtures are code, not binary blobs: drawn into CGContext PDFs with Core
// Text so font runs carry real metadata (PDFPage.attributedString and
// extractPositionedRuns see correct sizes/weights). Ground-truth strings are
// exposed as constants so invariant tests can assert byte-exactness.

enum PDFFixture {

    // MARK: Ground-truth content

    static let articleTitle = "Synthetic Test Document"

    /// Two body paragraphs with unique sentinel words (ZEBRAFISH / QUASAR) so
    /// tests can detect cross-paragraph text mixing without depending on how
    /// Vision segments the page.
    static let articleParagraphs = [
        "The first paragraph discusses the ZEBRAFISH experiment in detail. "
            + "It continues with additional context about the methodology used. "
            + "The final sentence of this paragraph concludes the first topic.",
        "The second paragraph turns to the QUASAR observations instead. "
            + "It presents findings that are entirely distinct from the first part. "
            + "A closing remark wraps up the second topic cleanly.",
    ]

    /// 4 rows × 3 cols. Row 0 is a bold header; column 2 is numeric.
    static let tableCells: [[String]] = [
        ["Item", "Category", "Amount"],
        ["Concrete mix", "Materials", "1,204.50"],
        ["Rebar bundle", "Materials", "386.20"],
        ["Crane rental", "Equipment", "2,750.00"],
    ]

    static let figureCaption = "Figure 1: Test diagram"

    // MARK: Page geometry (US Letter, PDF space is bottom-left Y-up)

    private static let pageWidth: CGFloat = 612
    private static let pageHeight: CGFloat = 792

    // MARK: Fixtures

    /// One page: 24pt Helvetica-Bold title + two 12pt Helvetica paragraphs.
    static func simpleArticle() throws -> URL {
        try drawPDF(named: "simple-article") { ctx in
            var y: CGFloat = pageHeight - 90
            drawLine(articleTitle, at: CGPoint(x: 72, y: y), size: 24, bold: true, in: ctx)
            y -= 50
            for para in articleParagraphs {
                y = drawWrappedParagraph(para, startY: y, in: ctx)
                y -= 26   // paragraph gap
            }
        }
    }

    /// One page: 3×4 ruled table with bold header row and a numeric column.
    static func simpleTable() throws -> URL {
        try drawPDF(named: "simple-table") { ctx in
            let left: CGFloat = 72
            let colWidths: [CGFloat] = [180, 140, 120]
            let rowHeight: CGFloat = 34
            let tableTop: CGFloat = pageHeight - 140
            let rows = tableCells.count
            let cols = tableCells[0].count
            let tableWidth = colWidths.reduce(0, +)

            // A heading above the table so the page isn't table-only.
            drawLine("Cost Summary", at: CGPoint(x: left, y: tableTop + 30), size: 18, bold: true, in: ctx)

            // Grid rules (0.75pt).
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
            ctx.setLineWidth(0.75)
            for r in 0...rows {
                let y = tableTop - CGFloat(r) * rowHeight
                ctx.stroke(CGRect(x: left, y: y, width: tableWidth, height: 0))
                ctx.move(to: CGPoint(x: left, y: y))
                ctx.addLine(to: CGPoint(x: left + tableWidth, y: y))
                ctx.strokePath()
            }
            var x = left
            for c in 0...cols {
                ctx.move(to: CGPoint(x: x, y: tableTop))
                ctx.addLine(to: CGPoint(x: x, y: tableTop - CGFloat(rows) * rowHeight))
                ctx.strokePath()
                if c < cols { x += colWidths[c] }
            }

            // Cell text (~6pt padding; baseline ~11pt above cell bottom).
            for (r, row) in tableCells.enumerated() {
                var cx = left
                for (c, text) in row.enumerated() {
                    let baselineY = tableTop - CGFloat(r + 1) * rowHeight + 11
                    drawLine(text, at: CGPoint(x: cx + 6, y: baselineY),
                             size: 11, bold: r == 0, in: ctx)
                    cx += colWidths[c]
                }
            }
        }
    }

    /// One page: gray rectangle (~40% of page, mid-page) + caption below it,
    /// plus one body paragraph near the top so the page isn't figure-only.
    static func pageWithFigure() throws -> URL {
        try drawPDF(named: "page-with-figure") { ctx in
            _ = drawWrappedParagraph(
                "This page contains a diagram referenced by the caption below it.",
                startY: pageHeight - 90, in: ctx
            )

            // Figure: gray filled rect. PDF space is Y-up: rect occupies the
            // vertical middle of the page.
            let figRect = CGRect(x: 96, y: 280, width: 420, height: 300)
            ctx.setFillColor(CGColor(gray: 0.55, alpha: 1))
            ctx.fill(figRect)

            // Caption just below the figure (lower y in PDF space).
            drawLine(figureCaption, at: CGPoint(x: 96, y: figRect.minY - 24),
                     size: 11, bold: false, in: ctx)
        }
    }

    /// simpleArticle rendered to a 300-DPI PNG, then wrapped as an image-only
    /// PDF (no text layer) — the "scanned" fixture.
    static func scannedArticle() throws -> (pdf: URL, png: URL) {
        let articleURL = try simpleArticle()

        // Rasterize via the production path.
        let pages = try Rasterizer.load(articleURL.path, dpi: 300, pageRange: nil)
        guard let page = pages.first else {
            throw FixtureError.rasterizationFailed
        }

        // Write the PNG.
        let pngURL = outputURL(named: "scanned-article", ext: "png")
        guard let dest = CGImageDestinationCreateWithURL(
            pngURL as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw FixtureError.pngWriteFailed }
        CGImageDestinationAddImage(dest, page.image, nil)
        guard CGImageDestinationFinalize(dest) else { throw FixtureError.pngWriteFailed }

        // Wrap the bitmap as an image-only PDF.
        let cgImage = page.image
        let pdfURL = try drawPDF(named: "scanned-article") { ctx in
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
        }
        return (pdf: pdfURL, png: pngURL)
    }

    // MARK: Drawing helpers

    enum FixtureError: Error {
        case contextCreationFailed
        case rasterizationFailed
        case pngWriteFailed
    }

    private static func outputURL(named name: String, ext: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("visionmd-fixtures-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(name).\(ext)")
    }

    @discardableResult
    private static func drawPDF(named name: String, draw: (CGContext) -> Void) throws -> URL {
        let url = outputURL(named: name, ext: "pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw FixtureError.contextCreationFailed
        }
        ctx.beginPDFPage(nil)
        // White background so the "scanned" raster isn't transparent.
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(mediaBox)
        draw(ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    /// Draw a single line of text with Core Text at a baseline point.
    private static func drawLine(
        _ text: String, at point: CGPoint, size: CGFloat, bold: Bool, in ctx: CGContext
    ) {
        let fontName = bold ? "Helvetica-Bold" : "Helvetica"
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }

    /// Draw a paragraph with fixed manual wrapping (~72 chars/line) at 12pt.
    /// Returns the y of the next free baseline.
    private static func drawWrappedParagraph(
        _ text: String, startY: CGFloat, in ctx: CGContext
    ) -> CGFloat {
        let maxLineLength = 72
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            if current.isEmpty {
                current = String(word)
            } else if current.count + word.count + 1 <= maxLineLength {
                current += " " + word
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }

        var y = startY
        for line in lines {
            drawLine(line, at: CGPoint(x: 72, y: y), size: 12, bold: false, in: ctx)
            y -= 16   // 12pt type on 16pt leading
        }
        return y
    }
}
