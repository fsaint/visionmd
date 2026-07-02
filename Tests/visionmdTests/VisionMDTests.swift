import CoreGraphics
import Foundation
import Testing
@testable import visionmd

// MARK: - Geometry tests

@Suite("Geometry")
struct GeometryTests {

    @Test("Vision → internal Y-flip")
    func visionToInternalFlip() {
        // A rect at the bottom of the Vision space (y ≈ 0) should appear at the
        // top of the internal space (y ≈ 0 after flip).
        let visionRect = CGRect(x: 0.1, y: 0.0, width: 0.8, height: 0.2)
        let internal_ = Geometry.visionToInternal(visionRect)
        #expect(abs(internal_.minY - 0.8) < 0.001)  // 1 - 0.2 = 0.8
        #expect(abs(internal_.maxY - 1.0) < 0.001)
        #expect(abs(internal_.minX - 0.1) < 0.001)
    }

    @Test("Vision → internal → Vision round-trip")
    func roundTrip() {
        let original = CGRect(x: 0.2, y: 0.3, width: 0.5, height: 0.15)
        let internal_ = Geometry.visionToInternal(original)
        let recovered = Geometry.internalToVision(internal_)
        #expect(abs(recovered.minX - original.minX) < 1e-6)
        #expect(abs(recovered.minY - original.minY) < 1e-6)
        #expect(abs(recovered.width  - original.width)  < 1e-6)
        #expect(abs(recovered.height - original.height) < 1e-6)
    }

    @Test("toPixels scales correctly")
    func toPixels() {
        let norm = CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
        let px = Geometry.toPixels(norm, pixelSize: CGSize(width: 2550, height: 3300))
        #expect(abs(px.minX - 637.5) < 1.0)
        #expect(abs(px.minY - 1650.0) < 1.0)
        #expect(abs(px.width  - 1275.0) < 1.0)
        #expect(abs(px.height -  825.0) < 1.0)
    }

    @Test("Negative space finds uncovered regions")
    func negativeSpace() {
        // Single occupied band in the middle — should yield top and bottom regions.
        let occupied = [CGRect(x: 0, y: 0.4, width: 1, height: 0.2)]
        let regions = Geometry.negativeSpace(minus: occupied, minArea: 0.05)
        #expect(regions.count == 2)
        #expect(regions.allSatisfy { $0.area >= 0.05 })
    }
}

// MARK: - Model tests

@Suite("Model")
struct ModelTests {

    @Test("PageRange single page")
    func pageRangeSingle() {
        let r = PageRange(string: "3")!
        #expect(r.contains(pageNumber: 3))
        #expect(!r.contains(pageNumber: 2))
        #expect(!r.contains(pageNumber: 4))
    }

    @Test("PageRange closed range")
    func pageRangeClosed() {
        let r = PageRange(string: "2-5")!
        #expect(!r.contains(pageNumber: 1))
        #expect(r.contains(pageNumber: 2))
        #expect(r.contains(pageNumber: 5))
        #expect(!r.contains(pageNumber: 6))
    }

    @Test("PageRange open-ended")
    func pageRangeOpen() {
        let r = PageRange(string: "8-")!
        #expect(!r.contains(pageNumber: 7))
        #expect(r.contains(pageNumber: 8))
        #expect(r.contains(pageNumber: 9999))
    }

    @Test("PageRange compound")
    func pageRangeCompound() {
        let r = PageRange(string: "1-3,7,10-12")!
        #expect(r.contains(pageNumber: 1))
        #expect(r.contains(pageNumber: 3))
        #expect(!r.contains(pageNumber: 4))
        #expect(r.contains(pageNumber: 7))
        #expect(r.contains(pageNumber: 10))
        #expect(r.contains(pageNumber: 12))
        #expect(!r.contains(pageNumber: 13))
    }

    @Test("PageRange invalid input returns nil")
    func pageRangeInvalid() {
        #expect(PageRange(string: "") == nil)
        #expect(PageRange(string: "abc") == nil)
    }

    @Test("TableModel denseGrid fills correctly")
    func tableModelDenseGrid() {
        let cells = [
            TableModel.Cell(row: 0, col: 0, rowSpan: 1, colSpan: 1, text: "A", confidence: 0.9),
            TableModel.Cell(row: 0, col: 1, rowSpan: 1, colSpan: 1, text: "B", confidence: 0.9),
            TableModel.Cell(row: 1, col: 0, rowSpan: 1, colSpan: 1, text: "C", confidence: 0.9),
            TableModel.Cell(row: 1, col: 1, rowSpan: 1, colSpan: 1, text: "D", confidence: 0.9),
        ]
        let table = TableModel(rowCount: 2, colCount: 2, cells: cells, confidence: 0.9)
        let grid = table.denseGrid()
        #expect(grid[0][0] == "A")
        #expect(grid[0][1] == "B")
        #expect(grid[1][0] == "C")
        #expect(grid[1][1] == "D")
        #expect(!table.hasMerges)
    }

    @Test("TableModel detects merges")
    func tableModelMerges() {
        let cells = [
            TableModel.Cell(row: 0, col: 0, rowSpan: 2, colSpan: 1, text: "Merged", confidence: 0.9),
        ]
        let table = TableModel(rowCount: 2, colCount: 2, cells: cells, confidence: 0.9)
        #expect(table.hasMerges)
    }
}

// MARK: - Markdown rendering tests

@Suite("MarkdownRenderer")
struct MarkdownRendererTests {
    let opts = MarkdownRenderer.Options(minConfidence: 0.5, emitHeadings: true, pageRules: false)

    @Test("Heading levels")
    func headingLevels() {
        let h1 = MarkdownRenderer.renderElement(
            .heading(level: 1, text: "Title", region: .unit, confidence: 0.9),
            pageIndex: 0, options: opts)
        #expect(h1 == "# Title")

        let h3 = MarkdownRenderer.renderElement(
            .heading(level: 3, text: "Sub", region: .unit, confidence: 0.9),
            pageIndex: 0, options: opts)
        #expect(h3 == "### Sub")
    }

    @Test("Barcode output")
    func barcode() {
        let md = MarkdownRenderer.renderElement(
            .barcode(payload: "https://example.com", symbology: "QR", region: .unit),
            pageIndex: 0, options: opts)
        #expect(md == "`[barcode:QR] https://example.com`")
    }

    @Test("Figure with caption")
    func figureWithCaption() {
        let md = MarkdownRenderer.renderElement(
            .figure(assetRelPath: "assets/page-1-fig-1.png", region: .unit, caption: "Detail view"),
            pageIndex: 0, options: opts)
        #expect(md.contains("![Detail view](assets/page-1-fig-1.png)"))
        #expect(md.contains("*Detail view*"))
    }
}

// MARK: - Table rendering tests

@Suite("TableRenderer")
struct TableRendererTests {

    @Test("Simple pipe table")
    func pipeTable() {
        let cells: [TableModel.Cell] = [
            .init(row: 0, col: 0, rowSpan: 1, colSpan: 1, text: "Name",  confidence: 0.9),
            .init(row: 0, col: 1, rowSpan: 1, colSpan: 1, text: "Size",  confidence: 0.9),
            .init(row: 1, col: 0, rowSpan: 1, colSpan: 1, text: "W1",    confidence: 0.9),
            .init(row: 1, col: 1, rowSpan: 1, colSpan: 1, text: "3'-0\"", confidence: 0.9),
        ]
        let table = TableModel(rowCount: 2, colCount: 2, cells: cells, confidence: 0.9)
        let md = TableRenderer.markdown(table, id: "t_p1_1", minConf: 0.5, tableConf: 0.9)
        #expect(md.contains("| Name | Size |"))
        #expect(md.contains("| W1 | 3'-0\" |"))
        #expect(!md.contains("<table"))
    }

    @Test("Pipe table escapes pipe characters")
    func pipeEscape() {
        let cells: [TableModel.Cell] = [
            .init(row: 0, col: 0, rowSpan: 1, colSpan: 1, text: "A|B", confidence: 0.9),
        ]
        let table = TableModel(rowCount: 1, colCount: 1, cells: cells, confidence: 0.9)
        let md = TableRenderer.markdown(table, id: "t", minConf: 0.5, tableConf: 0.9)
        #expect(md.contains("A\\|B"))
    }

    @Test("Merged cells produce HTML table")
    func mergedCells() {
        let cells: [TableModel.Cell] = [
            .init(row: 0, col: 0, rowSpan: 2, colSpan: 1, text: "Span", confidence: 0.9),
            .init(row: 0, col: 1, rowSpan: 1, colSpan: 1, text: "X",    confidence: 0.9),
            .init(row: 1, col: 1, rowSpan: 1, colSpan: 1, text: "Y",    confidence: 0.9),
        ]
        let table = TableModel(rowCount: 2, colCount: 2, cells: cells, confidence: 0.9)
        let md = TableRenderer.markdown(table, id: "t_p1_1", minConf: 0.5, tableConf: 0.9)
        #expect(md.contains("<table"))
        #expect(md.contains("rowspan=\"2\""))
        #expect(md.contains("<!-- visionmd:complex-table"))
    }

    @Test("Low-confidence callout")
    func lowConfidence() {
        let cells: [TableModel.Cell] = [
            .init(row: 0, col: 0, rowSpan: 1, colSpan: 1, text: "X", confidence: 0.3),
        ]
        let table = TableModel(rowCount: 1, colCount: 1, cells: cells, confidence: 0.3)
        let md = TableRenderer.markdown(table, id: "t", minConf: 0.5, tableConf: 0.3)
        #expect(md.contains("⚠️"))
        #expect(md.contains("0.30"))
    }
}

// MARK: - Sidecar JSON tests

@Suite("Sidecar")
struct SidecarTests {

    @Test("Escalation flags tables correctly")
    func escalationFlag() throws {
        let cells: [TableModel.Cell] = [
            .init(row: 0, col: 0, rowSpan: 2, colSpan: 1, text: "X", confidence: 0.3),
        ]
        let table = TableModel(rowCount: 2, colCount: 1, cells: cells, confidence: 0.3)
        let elements: [DocElement] = [.table(table, region: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.3), confidence: 0.3)]
        let result = PageResult(index: 0, pixelSize: CGSize(width: 2550, height: 3300), elements: elements)

        let doc = Sidecar.build(results: [result], source: "test.pdf", dpi: 300, minConfidence: 0.5)
        #expect(doc.pages.count == 1)
        let el = try #require(doc.pages[0].elements.first)
        #expect(el.escalate)
        #expect(el.complex == true)
        #expect(el.type == "table")
    }

    @Test("Sidecar bbox_norm uses top-left coords")
    func bboxNorm() throws {
        let region = CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.3)
        let elements: [DocElement] = [.paragraph(text: "Hello", region: region, confidence: 0.3)]
        let result = PageResult(index: 0, pixelSize: CGSize(width: 2550, height: 3300), elements: elements)
        let doc = Sidecar.build(results: [result], source: "test.pdf", dpi: 300, minConfidence: 0.5)
        let el = try #require(doc.pages[0].elements.first)
        #expect(abs(el.bboxNorm[0] - 0.1) < 0.001)
        #expect(abs(el.bboxNorm[1] - 0.2) < 0.001)
        #expect(abs(el.bboxNorm[2] - 0.9) < 0.001)
        #expect(abs(el.bboxNorm[3] - 0.5) < 0.001)
    }

    @Test("Figures are never escalated")
    func figuresNotEscalated() {
        let elements: [DocElement] = [
            .figure(assetRelPath: "assets/page-1-fig-1.png", region: .unit, caption: nil)
        ]
        let result = PageResult(index: 0, pixelSize: CGSize(width: 1000, height: 1000), elements: elements)
        let doc = Sidecar.build(results: [result], source: "test.pdf", dpi: 300, minConfidence: 0.5)
        #expect(doc.pages[0].elements.first?.escalate == false)
    }
}

// MARK: - PDFStructureExtractor tests

@Suite("PDFStructureExtractor")
struct PDFStructureExtractorTests {

    @Test("Body font size is weighted median (80% at 12pt, 20% at 24pt → 12pt)")
    func weightedMedian() {
        let bodyText = String(repeating: "x", count: 800)
        let headText = String(repeating: "H", count: 200)
        let runs = [
            PDFTextRun(text: bodyText, fontSize: 12, fontName: "Helvetica", isBold: false, isItalic: false),
            PDFTextRun(text: headText, fontSize: 24, fontName: "Helvetica-Bold", isBold: true, isItalic: false),
        ]
        #expect(PDFStructureExtractor.weightedMedianFontSize(runs: runs) == 12.0)
    }

    @Test("Font-size ratio 2.0 → H1")
    func fontRatioH1() {
        let fontInfo = PDFPageFontInfo(
            runs: [
                PDFTextRun(text: "REPORT TITLE", fontSize: 24, fontName: "Helvetica-Bold", isBold: true, isItalic: false),
                PDFTextRun(text: String(repeating: "body ", count: 100), fontSize: 12, fontName: "Helvetica", isBold: false, isItalic: false),
            ],
            bodyFontSize: 12
        )
        let el = LayoutResolver.classifyByFontSize(
            text: "REPORT TITLE",
            region: CGRect(x: 0.1, y: 0.05, width: 0.8, height: 0.06),
            confidence: 0.95,
            fontInfo: fontInfo
        )
        if case .heading(let level, _, _, _) = el {
            #expect(level == 1)
        } else {
            Issue.record("Expected heading(1), got \(el)")
        }
    }

    @Test("Field label is not classified as heading despite large font")
    func fieldLabelSuppression() {
        let fontInfo = PDFPageFontInfo(
            runs: [
                PDFTextRun(text: "Manufacturer: Sanofi", fontSize: 18, fontName: "Helvetica", isBold: false, isItalic: false),
            ],
            bodyFontSize: 10
        )
        let el = LayoutResolver.classifyByFontSize(
            text: "Manufacturer: Sanofi",
            region: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.05),
            confidence: 0.95,
            fontInfo: fontInfo
        )
        if case .paragraph = el {
            // expected — field labels suppressed
        } else {
            Issue.record("Expected paragraph (field label suppressed), got \(el)")
        }
    }

    // MARK: isNonHeadingContent guard tests

    @Test("Pure-numeric strings are not headings")
    func pureNumericSuppression() {
        // Phone number, date, project number — no letters, has digits
        for text in ["(413) 781-2021", "9/6/2024", "22044", "2025", "10.13333333"] {
            #expect(LayoutResolver.isNonHeadingContent(text),
                    "Expected '\(text)' to be non-heading")
        }
    }

    @Test("Digit-heavy strings with letter prefix are not headings")
    func digitHeavySuppression() {
        // Fax number like "F413.734.1881" — has letter F, but >65% digits
        #expect(LayoutResolver.isNonHeadingContent("F413.734.1881"))
    }

    @Test("Short strings under 6 chars are not headings")
    func shortStringSuppression() {
        for text in ["TBD", "005", "2301", "C3-B5", "SMMA"] {
            #expect(LayoutResolver.isNonHeadingContent(text),
                    "Expected '\(text)' to be non-heading (too short)")
        }
    }

    @Test("Real section headers pass the guard")
    func realHeadingsPassGuard() {
        for text in ["WEATHER REPORT", "Field Observation Report",
                     "CONSTRUCTION STATUS", "ACTION"] {
            #expect(!LayoutResolver.isNonHeadingContent(text),
                    "Expected '\(text)' to pass non-heading guard")
        }
    }

    @Test("Phone number with large font is not classified as heading")
    func phoneNumberNotHeading() {
        let fontInfo = PDFPageFontInfo(
            runs: [
                PDFTextRun(text: "(413) 781-2021", fontSize: 14, fontName: "Helvetica", isBold: false, isItalic: false),
            ],
            bodyFontSize: 10
        )
        let el = LayoutResolver.classifyByFontSize(
            text: "(413) 781-2021",
            region: CGRect(x: 0.1, y: 0.05, width: 0.4, height: 0.04),
            confidence: 0.95,
            fontInfo: fontInfo
        )
        if case .paragraph = el {
            // expected — phone number suppressed
        } else {
            Issue.record("Expected paragraph for phone number, got \(el)")
        }
    }

    @Test("All-caps text at body font size is classified as H3")
    func allCapsAtBodySizeIsH3() {
        let fontInfo = PDFPageFontInfo(
            runs: [
                PDFTextRun(text: "CONSTRUCTION FIELD REPORT #24", fontSize: 12, fontName: "Helvetica-Bold", isBold: true, isItalic: false),
                PDFTextRun(text: "Some body paragraph text here.", fontSize: 12, fontName: "Helvetica", isBold: false, isItalic: false),
            ],
            bodyFontSize: 12
        )
        let el = LayoutResolver.classifyByFontSize(
            text: "CONSTRUCTION FIELD REPORT #24",
            region: CGRect(x: 0.1, y: 0.05, width: 0.6, height: 0.03),
            confidence: 0.95,
            fontInfo: fontInfo
        )
        if case .heading(let level, _, _, _) = el {
            #expect(level == 3)
        } else {
            Issue.record("Expected H3 for all-caps body-size header, got \(el)")
        }
    }

    @Test("Short all-caps token (< 6 chars) is not classified as heading")
    func shortAllCapsNotHeading() {
        let fontInfo = PDFPageFontInfo(
            runs: [PDFTextRun(text: "TBD", fontSize: 12, fontName: "Helvetica", isBold: false, isItalic: false)],
            bodyFontSize: 12
        )
        let el = LayoutResolver.classifyByFontSize(
            text: "TBD",
            region: CGRect(x: 0.1, y: 0.05, width: 0.1, height: 0.02),
            confidence: 0.95,
            fontInfo: fontInfo
        )
        if case .paragraph = el { /* expected */ } else {
            Issue.record("Expected paragraph for short all-caps 'TBD', got \(el)")
        }
    }

    @Test("Scanned page (fontInfo = nil) uses heuristic fallback")
    func scannedPageFallback() {
        guard let img = makeTestImage() else {
            Issue.record("Could not create test image"); return
        }
        // 612×792 pt page (letter), fontInfo = nil → scanned path
        let page = RasterizedPage(
            index: 0,
            image: img,
            pixelSize: CGSize(width: 2550, height: 3300),
            pointSize: CGSize(width: 612, height: 792),
            dpi: 300,
            pdfTextLayer: nil,
            fontInfo: nil
        )
        // lineH = 0.06, medianLineH ≈ 12/792 ≈ 0.015, ratio ≈ 4.0 → H1
        let raw = RawDocumentResult(
            paragraphs: [RawParagraph(
                text: "SECTION TITLE",
                visionBBox: CGRect(x: 0.1, y: 0.7, width: 0.8, height: 0.06),
                confidence: 0.95,
                lineCount: 1
            )],
            tables: [], lists: [], barcodes: []
        )
        let elements = LayoutResolver.resolve(raw, page: page, minConfidence: 0.5)
        let isHeading = elements.contains { if case .heading = $0 { return true }; return false }
        #expect(isHeading, "Heuristic should classify SECTION TITLE as heading when fontInfo is nil")
    }

    private func makeTestImage() -> CGImage? {
        let w = 64, h = 64
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) { pixels[i * 4 + 3] = 255 }
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        return ctx.makeImage()
    }
}

// MARK: - Image stats tests

@Suite("ImageStats")
struct ImageStatsTests {

    @Test("All-white image is near-blank")
    func allWhite() {
        guard let img = makeMonochromeImage(r: 255, g: 255, b: 255) else {
            Issue.record("Could not create test image")
            return
        }
        #expect(ImageStats.isNearBlank(img))
    }

    @Test("Dark image is not near-blank")
    func darkImage() {
        guard let img = makeMonochromeImage(r: 50, g: 50, b: 50) else {
            Issue.record("Could not create test image")
            return
        }
        #expect(!ImageStats.isNearBlank(img))
    }

    private func makeMonochromeImage(r: UInt8, g: UInt8, b: UInt8) -> CGImage? {
        let w = 64, h = 64
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            pixels[i * 4 + 0] = r
            pixels[i * 4 + 1] = g
            pixels[i * 4 + 2] = b
            pixels[i * 4 + 3] = 255
        }
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        return ctx.makeImage()
    }
}
