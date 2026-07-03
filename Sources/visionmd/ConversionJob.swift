import CoreGraphics
import Foundation

// MARK: - Conversion job (testable pipeline entry point)
//
// VisionMD.run() resolves CLI options into ConversionOptions and delegates
// here. Tests construct ConversionJob directly with temp-dir URLs — no CLI,
// no process exit codes.

/// Plain Sendable domain options, decoupled from ArgumentParser.
struct ConversionOptions: Sendable {
    // Recognition
    var dpi: Double = 300
    var languages: [Locale.Language] = []
    var level: RecognitionLevel = .accurate
    var pageRange: PageRange? = nil
    // Routing / extraction
    var textLayerMode: TextLayerMode = .hybrid
    var tableMode: TableMode = .native
    var figureMode: FigureMode = .crop
    var minFigureArea: Double = 0.02
    var minConfidence: Float = 0.5
    // Rendering
    var emitHeadings: Bool = true
    var pageRules: Bool = false
    var frontMatter: Bool = false
    var keepPageFurniture: Bool = false
    var hashAssets: Bool = false
    // Output layout (resolved absolute URLs — tests point these at temp dirs)
    var outputURL: URL
    var assetsDirURL: URL
    var jsonURL: URL? = nil
    // Concurrency cap for Vision requests (tests lower this; see the SIGSEGV
    // note in execute()).
    var maxConcurrency: Int = 8
}

struct ConversionResult: Sendable {
    let markdown: String
    let pages: [PageResult]
    /// Figure PNGs written during execute (inside FigureExtractor).
    let assetURLs: [URL]
    /// Always built; the caller decides whether to write it.
    let sidecar: SidecarDocument
    let partialFailure: Bool
}

enum ConversionError: Error, CustomStringConvertible {
    case noPages
    case allPagesFailed

    var description: String {
        switch self {
        case .noPages:        "no pages to process (check --pages range)"
        case .allPagesFailed: "all pages failed"
        }
    }
}

struct ConversionJob: Sendable {
    let inputURL: URL
    let options: ConversionOptions
    var sourceName: String

    init(inputURL: URL, options: ConversionOptions, sourceName: String? = nil) {
        self.inputURL = inputURL
        self.options = options
        self.sourceName = sourceName ?? inputURL.lastPathComponent
    }

    /// Run the full pipeline. Figure PNGs are written to
    /// `options.assetsDirURL` DURING execution; the .md and sidecar JSON are
    /// returned, not written — the caller persists them.
    func execute() async throws -> ConversionResult {
        // Stage 1: Rasterize
        let rasterized = try Rasterizer.load(inputURL.path, dpi: options.dpi, pageRange: options.pageRange)
        guard !rasterized.isEmpty else { throw ConversionError.noPages }
        log("Loaded \(rasterized.count) page(s) at \(Int(options.dpi)) DPI")

        // Stages 2–5: Process pages concurrently.
        let opts = ProcessOptions(
            languages: options.languages,
            level: options.level,
            textLayerMode: options.textLayerMode,
            tableMode: options.tableMode,
            figureMode: options.figureMode,
            minFigureArea: options.minFigureArea,
            minConfidence: options.minConfidence,
            assetsDirURL: options.assetsDirURL,
            hashAssets: options.hashAssets
        )

        // Cap concurrent Vision requests: launching too many simultaneously on
        // large PDFs causes SIGSEGV in CoreAnalytics/CoreGraphics (JBIG2 decoder
        // state accumulates). 8 concurrent tasks saturates Apple Silicon without
        // triggering framework crashes.
        var partialFailure = false
        var results: [PageResult] = []
        results = try await withThrowingTaskGroup(of: PageResult?.self) { group in
            var iterator = rasterized.makeIterator()

            for _ in 0..<min(options.maxConcurrency, rasterized.count) {
                if let page = iterator.next() {
                    group.addTask {
                        do { return try await Pipeline.process(page, options: opts) }
                        catch { warn("Page \(page.index + 1) failed: \(error) — skipped"); return nil }
                    }
                }
            }

            var collected: [PageResult] = []
            for try await result in group {
                if let r = result { collected.append(r) } else { partialFailure = true }
                if let page = iterator.next() {
                    group.addTask {
                        do { return try await Pipeline.process(page, options: opts) }
                        catch { warn("Page \(page.index + 1) failed: \(error) — skipped"); return nil }
                    }
                }
            }
            return collected.sorted { $0.index < $1.index }
        }

        guard !results.isEmpty else { throw ConversionError.allPagesFailed }

        // Document-level refinement: drop repeated page headers/footers.
        if !options.keepPageFurniture {
            results = DocumentRefiner.removePageFurniture(results)
        }

        // Stage 6: Assemble Markdown.
        // Compute the assets-dir prefix relative to the output .md so figure
        // links actually resolve (assets default to "<stem>_assets").
        let assetsPrefix = Self.relativePrefix(
            from: options.outputURL.deletingLastPathComponent(),
            to: options.assetsDirURL
        )
        let mdOptions = MarkdownRenderer.Options(
            minConfidence: options.minConfidence,
            emitHeadings: options.emitHeadings,
            pageRules: options.pageRules,
            assetsPrefix: assetsPrefix
        )
        let assemblyOptions = Assembler.Options(
            frontMatter: options.frontMatter,
            pageComments: true,
            pageRules: options.pageRules,
            sourceFile: sourceName,
            dpi: options.dpi
        )
        let markdown = Assembler.assembleMarkdown(
            results: results,
            markdownOptions: mdOptions,
            assemblyOptions: assemblyOptions
        )

        let sidecar = Sidecar.build(
            results: results,
            source: sourceName,
            dpi: options.dpi,
            minConfidence: options.minConfidence
        )

        // Collect the figure asset URLs actually referenced.
        let assetURLs: [URL] = results.flatMap { page in
            page.elements.compactMap { el in
                if case .figure(let filename, _, _) = el {
                    return options.assetsDirURL.appendingPathComponent(filename)
                }
                return nil
            }
        }

        return ConversionResult(
            markdown: markdown,
            pages: results,
            assetURLs: assetURLs,
            sidecar: sidecar,
            partialFailure: partialFailure
        )
    }

    /// Relative path prefix from `base` dir to `target` dir ("" when equal,
    /// "name" when target is a direct child, ../-style path otherwise).
    static func relativePrefix(from base: URL, to target: URL) -> String {
        let baseComps = base.standardizedFileURL.pathComponents
        let targetComps = target.standardizedFileURL.pathComponents
        if baseComps == targetComps { return "" }
        if targetComps.count == baseComps.count + 1,
           Array(targetComps.prefix(baseComps.count)) == baseComps {
            return targetComps.last!
        }
        var common = 0
        while common < min(baseComps.count, targetComps.count),
              baseComps[common] == targetComps[common] { common += 1 }
        let ups = Array(repeating: "..", count: baseComps.count - common)
        let downs = targetComps[common...]
        return (ups + downs).joined(separator: "/")
    }
}
