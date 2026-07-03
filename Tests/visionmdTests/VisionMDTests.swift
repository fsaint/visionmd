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

// MARK: - Phase 1 correctness fixes

@Suite("Phase1Fixes")
struct Phase1FixTests {

    @Test("escapeCell escapes HTML entities before inserting <br>")
    func escapeCellOrder() {
        let out = TableRenderer.escapeCell("a<b & c\nd")
        #expect(out == "a&lt;b &amp; c<br>d")
    }

    @Test("escapeHTML escapes ampersand first")
    func escapeHTMLAmpFirst() {
        #expect(TableRenderer.escapeHTML("<&>") == "&lt;&amp;&gt;")
    }

    @Test("dedupeCells keeps one instance of a row-spanning cell")
    func dedupeSpanningCells() {
        let cells = [
            RawTable.RawCell(row: 0, col: 0, rowSpan: 2, colSpan: 1, text: "span", confidence: 0.9),
            RawTable.RawCell(row: 0, col: 1, rowSpan: 1, colSpan: 1, text: "b", confidence: 0.9),
            RawTable.RawCell(row: 0, col: 0, rowSpan: 2, colSpan: 1, text: "span", confidence: 0.9), // dup from row 1
            RawTable.RawCell(row: 1, col: 1, rowSpan: 1, colSpan: 1, text: "d", confidence: 0.9),
        ]
        let deduped = Recognizer.dedupeCells(cells)
        #expect(deduped.count == 3)
        #expect(deduped.filter { $0.text == "span" }.count == 1)
    }

    @Test("isUsableTextLayer ignores newlines and tabs")
    func garbleCheckWhitespace() {
        // Many newlines relative to text: a schedule-like layer. Must stay usable.
        let text = String(repeating: "AB\n", count: 100)
        #expect(Rasterizer.isUsableTextLayer(text))
        // Genuinely garbled: >10% replacement chars.
        let garbled = "AB\u{FFFD}\u{FFFD}\u{FFFD}"
        #expect(!Rasterizer.isUsableTextLayer(garbled))
    }

    @Test("Figure rendering prepends assets prefix and brackets spaced paths")
    func figureAssetPrefix() {
        var opts = MarkdownRenderer.Options(minConfidence: 0.5, emitHeadings: true, pageRules: false)
        opts.assetsPrefix = "my doc_assets"
        let el = DocElement.figure(assetRelPath: "page-1-fig-1.png",
                                   region: CGRect(x: 0, y: 0, width: 0.5, height: 0.3),
                                   caption: nil)
        let md = MarkdownRenderer.renderElement(el, pageIndex: 0, options: opts)
        #expect(md == "![figure](<my doc_assets/page-1-fig-1.png>)")
    }

    @Test("Table anchors are per-table and match sidecar scheme")
    func tableAnchorsMatchSidecar() {
        let merged = TableModel(
            rowCount: 2, colCount: 2,
            cells: [TableModel.Cell(row: 0, col: 0, rowSpan: 2, colSpan: 1, text: "x", confidence: 0.9)],
            confidence: 0.9
        )
        let result = PageResult(
            index: 0,
            pixelSize: CGSize(width: 100, height: 100),
            elements: [
                .table(merged, region: CGRect(x: 0, y: 0, width: 0.5, height: 0.2), confidence: 0.9),
                .table(merged, region: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.2), confidence: 0.9),
            ]
        )
        let opts = MarkdownRenderer.Options(minConfidence: 0.5, emitHeadings: true, pageRules: false)
        let md = MarkdownRenderer.renderPage(result, options: opts)
        #expect(md.contains("id=t_p1_1"))
        #expect(md.contains("id=t_p1_2"))
    }

    @Test("tables off suppresses tables and surfaces inside text")
    func tablesOffSurfacesText() {
        let page = RasterizedPage(
            index: 0, image: testCGImage(), pixelSize: CGSize(width: 100, height: 100),
            pointSize: CGSize(width: 612, height: 792), dpi: 300,
            pdfTextLayer: nil, fontInfo: nil
        )
        let tableBBox = CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.2)   // Vision space
        let raw = RawDocumentResult(
            paragraphs: [RawParagraph(text: "inside cell text",
                                      visionBBox: tableBBox.insetBy(dx: 0.05, dy: 0.05),
                                      confidence: 0.9, lineCount: 1)],
            tables: [RawTable(rowCount: 1, colCount: 1,
                              cells: [RawTable.RawCell(row: 0, col: 0, rowSpan: 1, colSpan: 1,
                                                       text: "inside cell text", confidence: 0.9)],
                              visionBBox: tableBBox, confidence: 0.9)],
            lists: [], barcodes: []
        )
        let withTables = LayoutResolver.resolve(raw, page: page, tableMode: .native)
        #expect(withTables.contains { if case .table = $0 { return true }; return false })
        #expect(!withTables.contains { if case .paragraph = $0 { return true }; return false })

        let without = LayoutResolver.resolve(raw, page: page, tableMode: .off)
        #expect(!without.contains { if case .table = $0 { return true }; return false })
        // The inside text must surface (as a paragraph or heading).
        #expect(without.contains { el in
            if case .paragraph = el { return true }
            if case .heading = el { return true }
            return false
        })
    }

    @Test("Caption must be below the figure")
    func captionBelowOnly() {
        let fig = CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.3)   // bottom at 0.6
        // Paragraph ABOVE the figure (would previously attach) — must not attach.
        var els: [DocElement] = [
            .figure(assetRelPath: "f.png", region: fig, caption: nil),
            .paragraph(text: "Header text", region: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.03), confidence: 0.9),
        ]
        FigureExtractor.associateCaptions(&els)
        if case .figure(_, _, let cap) = els[0] { #expect(cap == nil) }

        // Paragraph just below the figure — attaches.
        var els2: [DocElement] = [
            .figure(assetRelPath: "f.png", region: fig, caption: nil),
            .paragraph(text: "Figure 3: Site plan", region: CGRect(x: 0.1, y: 0.61, width: 0.5, height: 0.03), confidence: 0.9),
        ]
        FigureExtractor.associateCaptions(&els2)
        if case .figure(_, _, let cap) = els2[0] {
            #expect(cap == "Figure 3: Site plan")
        }
        #expect(els2.count == 1)   // caption paragraph consumed
    }

    @Test("Caption pattern preferred over closer plain paragraph")
    func captionPatternPreferred() {
        let fig = CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.3)
        var els: [DocElement] = [
            .figure(assetRelPath: "f.png", region: fig, caption: nil),
            .paragraph(text: "Some stray note", region: CGRect(x: 0.1, y: 0.605, width: 0.5, height: 0.02), confidence: 0.9),
            .paragraph(text: "Table 2: Loads", region: CGRect(x: 0.1, y: 0.625, width: 0.5, height: 0.02), confidence: 0.9),
        ]
        FigureExtractor.associateCaptions(&els)
        if case .figure(_, _, let cap) = els[0] {
            #expect(cap == "Table 2: Loads")
        }
    }

    private func testCGImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
}

// MARK: - Per-cell table reconciliation (Phase 5.1)

@Suite("TableReconciliation")
struct TableReconciliationTests {

    private func run(_ text: String, at rect: CGRect) -> PositionedTextRun {
        PositionedTextRun(text: text, rect: rect, fontSize: 11,
                          fontName: "Helvetica", isBold: false, isItalic: false)
    }

    private func cell(_ text: String, conf: Float, region: CGRect?) -> TableModel.Cell {
        TableModel.Cell(row: 0, col: 0, rowSpan: 1, colSpan: 1,
                        text: text, confidence: conf, region: region)
    }

    private func page(runs: [PositionedTextRun]) -> RasterizedPage {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return RasterizedPage(
            index: 0, image: ctx.makeImage()!,
            pixelSize: CGSize(width: 100, height: 100),
            pointSize: CGSize(width: 612, height: 792), dpi: 300,
            pdfTextLayer: "layer", fontInfo: nil,
            positionedRuns: runs,
            signals: PageSignals(hasTextLayer: true, garbleRatio: 0,
                                 layerCharCount: 1000, fullPageImage: false,
                                 hasFontInfo: true)
        )
    }

    @Test("Agreeing layer text replaces OCR cell text byte-exact")
    func layerReplacesCellText() {
        let cellRect = CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.04)
        let model = TableModel(rowCount: 1, colCount: 1,
                               cells: [cell("Concrete rnix", conf: 0.8, region: cellRect)],
                               confidence: 0.8)
        let p = page(runs: [run("Concrete mix", at: cellRect.insetBy(dx: 0.01, dy: 0.005))])
        let out = MixedSourceReconciler.reconcileTable(model, page: p, pageClass: .digital, thresholds: .hybrid)
        #expect(out.cells[0].text == "Concrete mix")
        #expect(out.cells[0].confidence >= 0.99)
        #expect(!out.cells[0].escalated)
    }

    @Test("Digit disagreement at low confidence escalates the cell")
    func digitDisagreementEscalates() {
        let cellRect = CGRect(x: 0.6, y: 0.2, width: 0.15, height: 0.04)
        let model = TableModel(rowCount: 1, colCount: 1,
                               cells: [cell("$1,204.50", conf: 0.3, region: cellRect)],
                               confidence: 0.3)
        // Layer disagrees on digits → digit-dense gate rejects; conf < 0.5 → escalate.
        let p = page(runs: [run("$8,777.99", at: cellRect.insetBy(dx: 0.01, dy: 0.005))])
        let out = MixedSourceReconciler.reconcileTable(model, page: p, pageClass: .digital, thresholds: .hybrid)
        #expect(out.cells[0].text == "$1,204.50")   // OCR kept
        #expect(out.cells[0].escalated)
        #expect(out.escalatedCells == [[0, 0]])
        #expect(out.hasEscalatedCells)
    }

    @Test("Cell without region passes through untouched")
    func noRegionPassthrough() {
        let model = TableModel(rowCount: 1, colCount: 1,
                               cells: [cell("as-is", conf: 0.7, region: nil)],
                               confidence: 0.7)
        let p = page(runs: [run("something else", at: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.04))])
        let out = MixedSourceReconciler.reconcileTable(model, page: p, pageClass: .digital, thresholds: .hybrid)
        #expect(out.cells[0].text == "as-is")
        #expect(!out.cells[0].escalated)
    }

    @Test("Adjacent cell runs do not bleed at cell tolerance")
    func noAdjacentCellBleed() {
        // Two side-by-side cells; the run for the neighbor sits 0.004 outside
        // this cell — inside paragraph tolerance (0.005) but outside cell
        // tolerance (0.002).
        let cellRect = CGRect(x: 0.10, y: 0.2, width: 0.20, height: 0.04)
        let neighborRun = run("NEIGHBOR", at: CGRect(x: 0.304, y: 0.2, width: 0.05, height: 0.04))
        let ownRun = run("OWN TEXT", at: cellRect.insetBy(dx: 0.02, dy: 0.005))
        let text = MixedSourceReconciler.collectRunText(in: cellRect,
                                                        runs: [ownRun, neighborRun],
                                                        tolerance: 0.002)
        #expect(text == "OWN TEXT")
    }
}

// MARK: - Heading-row demotion

@Suite("HeadingRows")
struct HeadingRowTests {

    private func heading(_ text: String, x: CGFloat, y: CGFloat) -> DocElement {
        .heading(level: 1, text: text, region: CGRect(x: x, y: y, width: 0.15, height: 0.02), confidence: 0.9)
    }

    @Test("Row of 3+ headings demoted to paragraphs")
    func headerRowDemoted() {
        let els = [
            heading("THIS PERIOD", x: 0.1, y: 0.20),
            heading("BALANCE", x: 0.4, y: 0.205),
            heading("STORED", x: 0.7, y: 0.198),
            heading("Real Title", x: 0.1, y: 0.05),
        ]
        let out = LayoutResolver.demoteHeadingRows(els)
        let headings = out.filter { if case .heading = $0 { return true }; return false }
        #expect(headings.count == 1)
        if case .heading(_, let t, _, _) = headings[0] { #expect(t == "Real Title") }
    }

    @Test("Two headings on one line survive")
    func pairSurvives() {
        let els = [
            heading("Chapter 1", x: 0.1, y: 0.1),
            heading("Appendix", x: 0.6, y: 0.1),
        ]
        let out = LayoutResolver.demoteHeadingRows(els)
        let headings = out.filter { if case .heading = $0 { return true }; return false }
        #expect(headings.count == 2)
    }

    @Test("Stacked two-line column headers demoted")
    func stackedHeadersDemoted() {
        // G703: "WORK COMPLETED" sits a line above "THIS PERIOD"/"BALANCE".
        let els = [
            heading("WORK COMPLETED", x: 0.30, y: 0.180),
            heading("THIS PERIOD", x: 0.45, y: 0.205),
            heading("BALANCE", x: 0.80, y: 0.205),
        ]
        let out = LayoutResolver.demoteHeadingRows(els)
        let headings = out.filter { if case .heading = $0 { return true }; return false }
        #expect(headings.isEmpty)
    }

    @Test("Wide pair of short all-caps labels demoted")
    func allCapsPairDemoted() {
        let els = [
            heading("THIS PERIOD", x: 0.2, y: 0.2),
            heading("BALANCE", x: 0.8, y: 0.2),
        ]
        let out = LayoutResolver.demoteHeadingRows(els)
        let headings = out.filter { if case .heading = $0 { return true }; return false }
        #expect(headings.isEmpty)
    }

    @Test("Left-aligned narrow heading stack survives (daily report sections)")
    func narrowStackSurvives() {
        // Sections at the same left edge, vertically close — NOT a table row.
        let els = [
            heading("DELIVERIES", x: 0.05, y: 0.30),
            heading("QUANTITIES", x: 0.05, y: 0.32),
            heading("DELAYS", x: 0.05, y: 0.34),
        ]
        let out = LayoutResolver.demoteHeadingRows(els)
        let headings = out.filter { if case .heading = $0 { return true }; return false }
        #expect(headings.count == 3)
    }

    @Test("Digit-dominated form page caps headings at H3")
    func formPageCapsHeadings() {
        var els: [DocElement] = [
            .heading(level: 1, text: "CONTINUATION SHEET",
                     region: CGRect(x: 0.3, y: 0.03, width: 0.4, height: 0.03), confidence: 0.9),
        ]
        for i in 0..<10 {
            els.append(.paragraph(text: "$\(i),492,395.0\(i)",
                                  region: CGRect(x: 0.1, y: 0.2 + CGFloat(i) * 0.05, width: 0.2, height: 0.02),
                                  confidence: 0.9))
        }
        let out = LayoutResolver.capHeadingsOnFormPages(els)
        if case .heading(let level, _, _, _) = out[0] {
            #expect(level == 3)
        } else {
            Issue.record("heading disappeared")
        }
    }

    @Test("Prose page keeps H1")
    func prosePageKeepsH1() {
        var els: [DocElement] = [
            .heading(level: 1, text: "SECTION 09 8453",
                     region: CGRect(x: 0.3, y: 0.03, width: 0.4, height: 0.03), confidence: 0.9),
        ]
        for i in 0..<10 {
            els.append(.paragraph(text: "Drawings and general provisions of the Contract apply.",
                                  region: CGRect(x: 0.1, y: 0.2 + CGFloat(i) * 0.05, width: 0.7, height: 0.02),
                                  confidence: 0.9))
        }
        let out = LayoutResolver.capHeadingsOnFormPages(els)
        if case .heading(let level, _, _, _) = out[0] {
            #expect(level == 1)
        }
    }
}

// MARK: - Document refinement (Phase 4)

@Suite("DocumentRefiner")
struct DocumentRefinerTests {

    private func pageResult(_ index: Int, elements: [DocElement]) -> PageResult {
        PageResult(index: index, pixelSize: CGSize(width: 100, height: 100), elements: elements)
    }

    private func header(_ text: String, page: Int) -> DocElement {
        .paragraph(text: text, region: CGRect(x: 0.1, y: 0.03, width: 0.5, height: 0.03), confidence: 0.9)
    }

    private func body(_ text: String) -> DocElement {
        .paragraph(text: text, region: CGRect(x: 0.1, y: 0.4, width: 0.6, height: 0.1), confidence: 0.9)
    }

    @Test("Repeated header removed from all pages")
    func repeatedHeaderRemoved() {
        let results = (0..<4).map { i in
            pageResult(i, elements: [header("ACME Corp — Confidential", page: i), body("page \(i) content")])
        }
        let refined = DocumentRefiner.removePageFurniture(results)
        for page in refined {
            #expect(page.elements.count == 1)
            if case .paragraph(let t, _, _) = page.elements[0] {
                #expect(t.hasPrefix("page"))
            }
        }
    }

    @Test("Numbered footers share a fingerprint and are removed")
    func numberedFootersRemoved() {
        let results = (0..<4).map { i in
            pageResult(i, elements: [
                body("content \(i)"),
                .paragraph(text: "Page \(i + 1) of 4",
                           region: CGRect(x: 0.4, y: 0.95, width: 0.2, height: 0.02), confidence: 0.9),
            ])
        }
        let refined = DocumentRefiner.removePageFurniture(results)
        for page in refined { #expect(page.elements.count == 1) }
    }

    @Test("Two-page documents are untouched")
    func twoPageUntouched() {
        let results = (0..<2).map { i in
            pageResult(i, elements: [header("Repeated Header", page: i), body("content")])
        }
        let refined = DocumentRefiner.removePageFurniture(results)
        for page in refined { #expect(page.elements.count == 2) }
    }

    @Test("Mid-page repeated text is NOT furniture")
    func midPageRepeatsKept() {
        // "ACTION" repeats on every page of a field report but sits mid-page.
        let results = (0..<5).map { i in
            pageResult(i, elements: [
                .heading(level: 3, text: "ACTION",
                         region: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.03), confidence: 0.9),
                body("item \(i)"),
            ])
        }
        let refined = DocumentRefiner.removePageFurniture(results)
        for page in refined { #expect(page.elements.count == 2) }
    }
}

// MARK: - Reading order (Phase 3)

@Suite("ReadingOrder")
struct ReadingOrderTests {

    private func page() -> RasterizedPage {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return RasterizedPage(index: 0, image: ctx.makeImage()!,
                              pixelSize: CGSize(width: 100, height: 100),
                              pointSize: CGSize(width: 612, height: 792), dpi: 300,
                              pdfTextLayer: nil, fontInfo: nil)
    }

    private func para(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat = 0.05) -> DocElement {
        .paragraph(text: text, region: CGRect(x: x, y: y, width: w, height: h), confidence: 0.9)
    }

    private func texts(_ els: [DocElement]) -> [String] {
        els.compactMap { if case .paragraph(let t, _, _) = $0 { return t }; return nil }
    }

    @Test("Footer sorts last, title first, columns in between")
    func titleColumnsFooter() {
        let els = [
            para("footer", x: 0.05, y: 0.93, w: 0.9),     // full-width bottom
            para("left-1", x: 0.05, y: 0.2, w: 0.4),
            para("right-1", x: 0.55, y: 0.2, w: 0.4),
            para("title", x: 0.05, y: 0.05, w: 0.9),      // full-width top
            para("left-2", x: 0.05, y: 0.4, w: 0.4),
            para("right-2", x: 0.55, y: 0.4, w: 0.4),
        ]
        let ordered = texts(LayoutResolver.order(els, page: page()))
        #expect(ordered == ["title", "left-1", "left-2", "right-1", "right-2", "footer"])
    }

    @Test("Full-width figure mid-page stays mid-page")
    func figureStaysMidPage() {
        let fig = DocElement.figure(assetRelPath: "f.png",
                                    region: CGRect(x: 0.05, y: 0.45, width: 0.9, height: 0.2),
                                    caption: nil)
        let els: [DocElement] = [
            para("above", x: 0.1, y: 0.1, w: 0.5),
            fig,
            para("below", x: 0.1, y: 0.75, w: 0.5),
        ]
        let ordered = LayoutResolver.order(els, page: page())
        // Expect: above, figure, below — the old sort hoisted the figure to the top.
        if case .paragraph(let t, _, _) = ordered[0] { #expect(t == "above") }
        if case .figure = ordered[1] {} else { Issue.record("figure not mid-sequence: \(ordered)") }
        if case .paragraph(let t, _, _) = ordered[2] { #expect(t == "below") }
    }
}

// MARK: - Source policy (Phase 2)

@Suite("SourcePolicy")
struct SourcePolicyTests {

    private func signals(
        hasLayer: Bool = true, garble: CGFloat = 0.0, chars: Int = 1000,
        fullImage: Bool = false, fontInfo: Bool = true
    ) -> PageSignals {
        PageSignals(hasTextLayer: hasLayer, garbleRatio: garble,
                    layerCharCount: chars, fullPageImage: fullImage,
                    hasFontInfo: fontInfo)
    }

    @Test("Digital page classification")
    func classifyDigital() {
        #expect(SourcePolicy.classify(signals: signals(), ocrCharCount: 1000) == .digital)
    }

    @Test("Scanned: no usable layer")
    func classifyScanned() {
        #expect(SourcePolicy.classify(signals: signals(hasLayer: false, chars: 0), ocrCharCount: 500) == .scanned)
        #expect(SourcePolicy.classify(signals: signals(garble: 0.2), ocrCharCount: 500) == .scanned)
    }

    @Test("Scanned with OCR layer: full-page image + layer")
    func classifyScannedOCRLayer() {
        #expect(SourcePolicy.classify(signals: signals(fullImage: true), ocrCharCount: 1000) == .scannedWithOCRLayer)
    }

    @Test("Mixed: layer covers < 60% of OCR text")
    func classifyMixed() {
        #expect(SourcePolicy.classify(signals: signals(chars: 100), ocrCharCount: 1000) == .mixed)
    }

    @Test("chooseText: no runs → OCR")
    func chooseNoRuns() {
        #expect(SourcePolicy.chooseText(ocr: "hello", ocrConfidence: 0.9,
                                        layerText: nil, pageClass: .digital) == .ocr)
    }

    @Test("chooseText: agreeing layer accepted on digital pages")
    func chooseLayerAccepted() {
        let choice = SourcePolicy.chooseText(
            ocr: "Proposals were solicited from ten companies",
            ocrConfidence: 0.7,
            layerText: "Proposals were solicited from ten companies.",
            pageClass: .digital
        )
        #expect(choice == .layer("Proposals were solicited from ten companies."))
    }

    @Test("chooseText: wildly different layer rejected")
    func chooseLayerRejected() {
        let choice = SourcePolicy.chooseText(
            ocr: "WEATHER REPORT",
            ocrConfidence: 0.9,
            layerText: "totally unrelated content that came from another region entirely and shares nothing",
            pageClass: .digital
        )
        #expect(choice == .ocr)
    }

    @Test("chooseText: digit-dense requires 0.85 similarity")
    func chooseDigitDense() {
        // Digit swap: 1,492,395 vs 1,492,895 — high sim but the gate protects
        // only below 0.85; verify a clearly different amount is rejected.
        let rejected = SourcePolicy.chooseText(
            ocr: "$1,492,395.00", ocrConfidence: 0.9,
            layerText: "$8,215,777.99", pageClass: .digital
        )
        #expect(rejected == .ocr)

        let escalated = SourcePolicy.chooseText(
            ocr: "$1,492,395.00", ocrConfidence: 0.3,
            layerText: "$8,215,777.99", pageClass: .digital
        )
        #expect(escalated == .ocrEscalate)

        let accepted = SourcePolicy.chooseText(
            ocr: "$1,492,395.00", ocrConfidence: 0.9,
            layerText: "$1,492,395.00", pageClass: .digital
        )
        #expect(accepted == .layer("$1,492,395.00"))
    }

    @Test("chooseText: scannedWithOCRLayer prefers OCR unless strong agreement")
    func chooseOCRLayerClass() {
        // Similar but not ≥0.85 → OCR wins on re-OCR'd scans.
        let choice = SourcePolicy.chooseText(
            ocr: "CONSTRUCTION FIELD REPORT",
            ocrConfidence: 0.9,
            layerText: "CONSTRUCTOIN FIELD REPROT extra words here",
            pageClass: .scannedWithOCRLayer
        )
        #expect(choice == .ocr)

        let agree = SourcePolicy.chooseText(
            ocr: "CONSTRUCTION FIELD REPORT",
            ocrConfidence: 0.9,
            layerText: "CONSTRUCTION FIELD REPORT",
            pageClass: .scannedWithOCRLayer
        )
        #expect(agree == .layer("CONSTRUCTION FIELD REPORT"))
    }

    @Test("isDigitDense boundary")
    func digitDense() {
        #expect(SourcePolicy.isDigitDense("$1,492,395.00"))
        #expect(SourcePolicy.isDigitDense("RFI #217 12/19/25"))
        #expect(!SourcePolicy.isDigitDense("Proposals were solicited from ten companies"))
    }

    @Test("Space-deficient layer text rejected in favor of OCR")
    func spaceDeficientLayer() {
        // PDF layer with positional spacing dropped: "1.01 RELATEDDOCUMENTS"
        let choice = SourcePolicy.chooseText(
            ocr: "1.01 RELATED DOCUMENTS",
            ocrConfidence: 0.95,
            layerText: "1.01 RELATEDDOCUMENTS",
            pageClass: .digital
        )
        #expect(choice == .ocr)

        // Layer with normal spacing still accepted.
        let ok = SourcePolicy.chooseText(
            ocr: "1.01 RELATED DOCUMENTS",
            ocrConfidence: 0.95,
            layerText: "1.01 RELATED DOCUMENTS",
            pageClass: .digital
        )
        #expect(ok == .layer("1.01 RELATED DOCUMENTS"))
    }

    @Test("isSpaceDeficient boundaries")
    func spaceDeficientBounds() {
        #expect(SourcePolicy.isSpaceDeficient(layer: "SOUNDBARRIERMULLIONTRIMCAP", ocr: "SOUND BARRIER MULLION TRIM CAP"))
        #expect(!SourcePolicy.isSpaceDeficient(layer: "two words", ocr: "two words"))
        // Under 2 OCR spaces → no signal, never triggers.
        #expect(!SourcePolicy.isSpaceDeficient(layer: "oneword", ocr: "one word"))
    }
}

// MARK: - Text similarity + cleaner (Phase 2)

@Suite("TextSupport")
struct TextSupportTests {

    @Test("Similarity: identical after normalization")
    func simIdentical() {
        #expect(TextSimilarity.similarity("Hello  World", "hello world") == 1.0)
    }

    @Test("Similarity: distinct strings score low")
    func simDistinct() {
        #expect(TextSimilarity.similarity("weather report", "invoice number 12345") < 0.5)
    }

    @Test("Similarity: minor OCR error scores high")
    func simOCRError() {
        #expect(TextSimilarity.similarity("CONSTRUCTION FIELD REPORT", "CONSTRUCTI0N FIELD REP0RT") > 0.85)
    }

    @Test("Cleaner: ligatures, soft hyphen, nbsp, space runs")
    func cleanerTransforms() {
        #expect(TextCleaner.normalize("e\u{FB03}cient") == "efficient")
        #expect(TextCleaner.normalize("hy\u{00AD}phen") == "hyphen")
        #expect(TextCleaner.normalize("a\u{00A0}b") == "a b")
        #expect(TextCleaner.normalize("a   b\tc") == "a b c")
    }

    @Test("collectRunText joins runs in reading order")
    func runCollection() {
        let runs = [
            PositionedTextRun(text: "right", rect: CGRect(x: 0.5, y: 0.10, width: 0.2, height: 0.02),
                              fontSize: 12, fontName: "Helvetica", isBold: false, isItalic: false),
            PositionedTextRun(text: "left", rect: CGRect(x: 0.1, y: 0.10, width: 0.2, height: 0.02),
                              fontSize: 12, fontName: "Helvetica", isBold: false, isItalic: false),
            PositionedTextRun(text: "second line", rect: CGRect(x: 0.1, y: 0.14, width: 0.4, height: 0.02),
                              fontSize: 12, fontName: "Helvetica", isBold: false, isItalic: false),
            PositionedTextRun(text: "outside", rect: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.02),
                              fontSize: 12, fontName: "Helvetica", isBold: false, isItalic: false),
        ]
        let region = CGRect(x: 0.05, y: 0.08, width: 0.7, height: 0.12)
        let text = MixedSourceReconciler.collectRunText(in: region, runs: runs)
        #expect(text == "left right\nsecond line")
    }

    @Test("collectRunText returns nil when no runs match")
    func runCollectionEmpty() {
        let runs = [
            PositionedTextRun(text: "far away", rect: CGRect(x: 0.1, y: 0.9, width: 0.2, height: 0.02),
                              fontSize: 12, fontName: "Helvetica", isBold: false, isItalic: false),
        ]
        let region = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1)
        #expect(MixedSourceReconciler.collectRunText(in: region, runs: runs) == nil)
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
        // Fax number: has letter F, but >65% digits
        #expect(LayoutResolver.isNonHeadingContent("F413.734.1881"))
        // 20-char invoice ref — previously escaped n<20 check, now caught by n<=30
        #expect(LayoutResolver.isNonHeadingContent("X5112300150102883054"))
        // 25-char order ref
        #expect(LayoutResolver.isNonHeadingContent("X51123001501028830541"))
    }

    @Test("Letter-sparse strings are not headings")
    func letterSparseSuppression() {
        // Order number with one letter in a long reference string
        #expect(LayoutResolver.isNonHeadingContent("004397- 0003 01. 0005 - 2300000- 19250 0001D"))
        // Barely passes the 15-char + <5% letter threshold
        #expect(LayoutResolver.isNonHeadingContent("0043970000300050001D"))
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

    @Test("Page furniture, addresses, and ID codes are not headings")
    func furnitureAddressIDSuppression() {
        for text in ["Page 4 of 5", "page 1 of 1",
                     "SPRINGFIELD, MA 01104",
                     "Great Barrington, Massachusetts 01230",
                     "SITE-1250", "SITS.1271", "SITE-114)"] {
            #expect(LayoutResolver.isNonHeadingContent(text),
                    "Expected '\(text)' to be non-heading")
        }
        // Headings containing an inline number must still pass.
        for text in ["CONSTRUCTION FIELD REPORT #24", "SECTION 09 8453", "Common Space Roof"] {
            #expect(!LayoutResolver.isNonHeadingContent(text),
                    "Expected '\(text)' to pass")
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

    @Test("Low-confidence text is never promoted to heading")
    func lowConfidenceNotHeading() {
        let fontInfo = PDFPageFontInfo(
            runs: [PDFTextRun(text: "INVOICE", fontSize: 24, fontName: "Helvetica-Bold", isBold: true, isItalic: false)],
            bodyFontSize: 10
        )
        // ratio = 2.4 → would normally be H1, but confidence < 0.55 gates it
        let el = LayoutResolver.classifyByFontSize(
            text: "INVOICE",
            region: CGRect(x: 0.1, y: 0.05, width: 0.3, height: 0.04),
            confidence: 0.40,
            fontInfo: fontInfo
        )
        if case .paragraph = el { /* expected */ } else {
            Issue.record("Expected paragraph for low-confidence text, got \(el)")
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
        let elements = LayoutResolver.resolve(raw, page: page)
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
