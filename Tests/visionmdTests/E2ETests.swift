import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import visionmd

// MARK: - Fixture sanity (no Vision required)

@Suite("Fixtures")
struct FixtureTests {

    @Test("simpleArticle has a text layer with real font runs")
    func articleFixture() throws {
        let url = try PDFFixture.simpleArticle()
        let doc = try #require(PDFDocument(url: url))
        #expect(doc.pageCount == 1)
        let page = try #require(doc.page(at: 0))
        let text = page.string ?? ""
        #expect(text.contains(PDFFixture.articleTitle))
        #expect(text.contains("ZEBRAFISH"))
        #expect(text.contains("QUASAR"))

        // Positioned runs must carry the 24pt bold title metadata.
        let runs = PDFStructureExtractor.extractPositionedRuns(from: page)
        #expect(!runs.isEmpty)
        let titleRun = runs.first { $0.text.contains("Synthetic") }
        #expect(titleRun?.fontSize == 24)
        #expect(titleRun?.isBold == true)
    }

    @Test("scannedArticle PDF has no text layer; PNG exists")
    func scannedFixture() throws {
        let (pdf, png) = try PDFFixture.scannedArticle()
        let doc = try #require(PDFDocument(url: pdf))
        let page = try #require(doc.page(at: 0))
        let layer = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        #expect(layer.isEmpty, "image-only PDF must have no text layer")
        #expect(FileManager.default.fileExists(atPath: png.path))
        // Classification from static signals: scanned.
        let pages = try Rasterizer.load(pdf.path, dpi: 150, pageRange: nil)
        let signals = try #require(pages.first?.signals)
        #expect(SourcePolicy.classify(signals: signals, ocrCharCount: 1000) == .scanned)
    }

    @Test("simpleTable fixture draws all ground-truth cells into the layer")
    func tableFixture() throws {
        let url = try PDFFixture.simpleTable()
        let doc = try #require(PDFDocument(url: url))
        let text = doc.page(at: 0)?.string ?? ""
        for row in PDFFixture.tableCells {
            for cell in row {
                #expect(text.contains(cell), "layer missing cell '\(cell)'")
            }
        }
    }
}

// MARK: - End-to-end pipeline invariants (Vision required)

@Suite("E2E", .serialized)
struct E2ETests {

    /// Run a ConversionJob against a fixture with test-friendly options
    /// (low concurrency to avoid the documented Vision SIGSEGV under test
    /// parallelism) and write the markdown so link checks see the real layout.
    private func runJob(
        _ input: URL,
        configure: (inout ConversionOptions) -> Void = { _ in }
    ) async throws -> (result: ConversionResult, outDir: URL) {
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("visionmd-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var options = ConversionOptions(
            outputURL: outDir.appendingPathComponent("out.md"),
            assetsDirURL: outDir.appendingPathComponent("out_assets")
        )
        options.maxConcurrency = 2
        configure(&options)

        let job = ConversionJob(inputURL: input, options: options)
        let result = try await job.execute()
        try result.markdown.write(to: options.outputURL, atomically: true, encoding: .utf8)
        return (result, outDir)
    }

    private func markdownLinks(_ markdown: String) throws -> [String] {
        let re = try NSRegularExpression(pattern: "!\\[[^\\]]*\\]\\((<[^>]+>|[^)]+)\\)")
        let ns = markdown as NSString
        return re.matches(in: markdown, range: NSRange(location: 0, length: ns.length)).map { m in
            var t = ns.substring(with: m.range(at: 1))
            if t.hasPrefix("<") { t = String(t.dropFirst().dropLast()) }
            return t
        }
    }

    @Test("Asset links resolve on disk", .enabled(if: VisionGate.available))
    func assetLinksResolve() async throws {
        let (result, outDir) = try await runJob(try PDFFixture.pageWithFigure())

        for url in result.assetURLs {
            #expect(FileManager.default.fileExists(atPath: url.path), "missing asset \(url.lastPathComponent)")
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            #expect(size > 0)
        }
        for link in try markdownLinks(result.markdown) {
            let target = outDir.appendingPathComponent(link)
            #expect(FileManager.default.fileExists(atPath: target.path), "broken link \(link)")
        }
    }

    @Test("Digital table cells byte-exact", .enabled(if: VisionGate.available))
    func tableCellsByteExact() async throws {
        // Fixed by Phase 5.1 (per-cell mixed-source text) — red until then.
        let (result, _) = try await runJob(try PDFFixture.simpleTable())

        // Collect all pipe-table cells from the markdown.
        let cells = Set(
            result.markdown
                .components(separatedBy: "\n")
                .filter { $0.hasPrefix("|") }
                .flatMap { $0.components(separatedBy: "|") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        var missing: [String] = []
        for row in PDFFixture.tableCells {
            for cell in row where !cells.contains(cell) {
                missing.append(cell)
            }
        }
        #expect(missing.isEmpty, "cells not byte-exact in output: \(missing)")
    }

    @Test("Reconciler never grows text across paragraphs", .enabled(if: VisionGate.available))
    func reconcilerNeverGrowsText() async throws {
        let (result, _) = try await runJob(try PDFFixture.simpleArticle())

        // No markdown block may contain sentinels from both source paragraphs.
        let blocks = result.markdown.components(separatedBy: "\n\n")
        for block in blocks {
            let hasFirst = block.contains("ZEBRAFISH")
            let hasSecond = block.contains("QUASAR")
            #expect(!(hasFirst && hasSecond), "paragraph mixing detected in block: \(block.prefix(120))")
        }

        // Each source paragraph appears byte-exact (digital page → layer wins).
        for para in PDFFixture.articleParagraphs {
            #expect(result.markdown.contains(para), "source paragraph not byte-exact: \(para.prefix(60))")
        }
    }

    @Test("Scanned page OCR reaches 0.9 similarity", .enabled(if: VisionGate.available))
    func scannedAccuracy() async throws {
        let (_, png) = try PDFFixture.scannedArticle()
        let (result, _) = try await runJob(png)

        let sourceText = TextCleaner.normalize(
            ([PDFFixture.articleTitle] + PDFFixture.articleParagraphs).joined(separator: " ")
        ).lowercased()
        let ocrText = TextCleaner.normalize(
            result.pages.flatMap { page in
                page.elements.compactMap { el -> String? in
                    switch el {
                    case .paragraph(let t, _, _), .heading(_, let t, _, _): return t
                    default: return nil
                    }
                }
            }.joined(separator: " ")
        ).lowercased()

        let sim = TextSimilarity.similarity(sourceText, ocrText, prefixLength: 600)
        #expect(sim >= 0.9, "scanned OCR similarity \(sim) < 0.9")
    }
}
