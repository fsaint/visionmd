import ArgumentParser
import Foundation

// MARK: - Entry point

@main
struct VisionMD: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "visionmd",
        abstract: "PDF/image → Markdown with tables and figures, via Apple Vision.",
        version: "0.1"
    )

    // MARK: Arguments & options

    @Argument(help: "Input .pdf, image (.png/.jpg/.heic/.tiff), or directory of images.")
    var input: String

    @Option(name: [.short, .customLong("output")], help: "Output .md path. Default: <input-stem>.md")
    var output: String?

    @Option(name: .customLong("assets-dir"), help: "Directory for extracted figures.")
    var assetsDir: String?

    @Option(help: "Rasterization DPI for PDF pages. Default: 300")
    var dpi: Double = 300

    @Option(help: "Comma-separated BCP-47 language codes, e.g. en-US,es-ES. Default: auto-detect.")
    var lang: String?

    @Option(help: "Recognition level: fast or accurate. Default: accurate")
    var level: String = "accurate"

    @Option(help: "Page range, e.g. 1-5,8,11-. Default: all")
    var pages: String?

    @Option(name: .customLong("text-layer"), help: "off | prefer | hybrid. Default: hybrid")
    var textLayerRaw: String = "hybrid"

    @Option(help: "Table mode: native | off. Default: native")
    var tables: String = "native"

    @Option(help: "Figure mode: crop | off. Default: crop")
    var figures: String = "crop"

    @Option(name: .customLong("min-figure-area"),
            help: "Min fraction of page area for a figure crop. Default: 0.02")
    var minFigureArea: Double = 0.02

    @Flag(name: .customLong("emit-json"), help: "Write sidecar JSON to <output-stem>.ocr.json.")
    var emitJson: Bool = false

    @Option(name: .customLong("json-output"),
            help: "Custom path for the sidecar JSON (implies --emit-json).")
    var emitJsonPath: String?

    @Option(name: .customLong("min-confidence"),
            help: "Elements below this confidence are flagged. Default: 0.5")
    var minConfidence: Double = 0.5

    @Flag(name: .customLong("front-matter"),
          help: "Prepend YAML front matter (source, pages, tool version).")
    var frontMatter: Bool = false

    @Flag(name: .customLong("page-rules"),
          help: "Insert Markdown rules (---) at page boundaries in addition to HTML comments.")
    var pageRules: Bool = false

    @Flag(name: .customLong("hash-assets"),
          help: "Append 8-char content hash to asset filenames for stable diffs.")
    var hashAssets: Bool = false

    @Flag(name: .customLong("no-headings"),
          help: "Disable heading inference; emit all text as paragraphs.")
    var noHeadings: Bool = false

    @Flag(help: "Suppress informational output.")
    var quiet: Bool = false

    @Flag(help: "Verbose logging.")
    var verbose: Bool = false

    // MARK: Run

    func run() async throws {
        // Logging level
        if quiet   { globalLogLevel = .quiet }
        if verbose { globalLogLevel = .verbose }

        // Validate and parse options
        let recognitionLevel = parseLevel()
        let textLayerMode = parseTextLayer()
        let tableMode = parseTableMode()
        let figureMode = parseFigureMode()
        let pageRange = try parsePageRange()
        let languages = resolvedLanguages()

        // OS guard: native table detection requires macOS 26.
        if tableMode == .native, #unavailable(macOS 26) {
            fputs("error: --tables native requires macOS 26 (Tahoe) or later.\n", stderr)
            fputs("       Use --tables off to run on macOS 15, or recompile for macOS 26.\n", stderr)
            throw ExitCode(2)
        }

        // Resolve output paths.
        let inputURL  = URL(fileURLWithPath: input)
        let stem      = inputURL.deletingPathExtension().lastPathComponent
        let outputURL = resolveOutputURL(stem: stem)
        let assetsDirURL = resolveAssetsDirURL(outputURL: outputURL, stem: stem)
        let jsonURL   = resolveJsonURL(outputURL: outputURL, stem: stem)

        log("Input:  \(inputURL.path)")
        log("Output: \(outputURL.path)")

        // Stage 1: Rasterize
        let rasterized = try Rasterizer.load(input, dpi: dpi, pageRange: pageRange)
        guard !rasterized.isEmpty else {
            fputs("visionmd: no pages to process (check --pages range)\n", stderr)
            throw ExitCode(1)
        }
        log("Loaded \(rasterized.count) page(s) at \(Int(dpi)) DPI")

        // Stages 2–5: Process pages concurrently.
        var results: [PageResult] = []
        var partialFailure = false

        let opts = ProcessOptions(
            languages: languages,
            level: recognitionLevel,
            textLayerMode: textLayerMode,
            tableMode: tableMode,
            figureMode: figureMode,
            minFigureArea: minFigureArea,
            minConfidence: Float(minConfidence),
            assetsDirURL: assetsDirURL,
            hashAssets: hashAssets
        )

        // Cap concurrent Vision requests: launching too many simultaneously on
        // large PDFs causes SIGSEGV in CoreAnalytics/CoreGraphics (JBIG2 decoder
        // state accumulates). 8 concurrent tasks saturates Apple Silicon without
        // triggering framework crashes.
        let maxConcurrency = 8
        results = try await withThrowingTaskGroup(of: PageResult?.self) { group in
            var iterator = rasterized.makeIterator()

            // Seed up to maxConcurrency initial tasks.
            for _ in 0..<min(maxConcurrency, rasterized.count) {
                if let page = iterator.next() {
                    group.addTask {
                        do { return try await Pipeline.process(page, options: opts) }
                        catch { warn("Page \(page.index + 1) failed: \(error) — skipped"); return nil }
                    }
                }
            }

            // Drain: for each finished task, start the next pending page.
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

        if results.isEmpty {
            fputs("visionmd: all pages failed\n", stderr)
            throw ExitCode(1)
        }

        // Stage 6: Assemble Markdown output.
        // Compute the assets-dir prefix relative to the output .md so figure
        // links actually resolve (assets default to "<stem>_assets").
        let assetsPrefix = relativePrefix(from: outputURL.deletingLastPathComponent(),
                                          to: assetsDirURL)
        let mdOptions = MarkdownRenderer.Options(
            minConfidence: Float(minConfidence),
            emitHeadings: !noHeadings,
            pageRules: pageRules,
            assetsPrefix: assetsPrefix
        )
        let assemblyOptions = Assembler.Options(
            frontMatter: frontMatter,
            pageComments: true,
            pageRules: pageRules,
            sourceFile: inputURL.lastPathComponent,
            dpi: dpi
        )
        let markdown = Assembler.assembleMarkdown(
            results: results,
            markdownOptions: mdOptions,
            assemblyOptions: assemblyOptions
        )

        // Write Markdown.
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try markdown.write(to: outputURL, atomically: true, encoding: .utf8)
        log("Markdown written → \(outputURL.path) (\(markdown.utf8.count) bytes)")

        // Write sidecar JSON (if requested).
        if let jsonDest = jsonURL {
            let sidecarDoc = Sidecar.build(
                results: results,
                source: inputURL.lastPathComponent,
                dpi: dpi,
                minConfidence: Float(minConfidence)
            )
            try Sidecar.write(sidecarDoc, to: jsonDest)
        }

        if partialFailure { throw ExitCode(3) }
    }

    // MARK: Option parsing helpers

    private func parseLevel() -> RecognitionLevel {
        switch level.lowercased() {
        case "fast":     return .fast
        case "accurate": return .accurate
        default:
            warn("Unknown recognition level '\(level)'; using accurate")
            return .accurate
        }
    }

    private func parseTextLayer() -> TextLayerMode {
        switch textLayerRaw.lowercased() {
        case "off":     return .off
        case "prefer":  return .prefer
        case "hybrid":  return .hybrid
        default:
            warn("Unknown text-layer mode '\(textLayerRaw)'; using hybrid")
            return .hybrid
        }
    }

    private func parseTableMode() -> TableMode {
        switch tables.lowercased() {
        case "native": return .native
        case "off":    return .off
        default:
            warn("Unknown table mode '\(tables)'; using native")
            return .native
        }
    }

    private func parseFigureMode() -> FigureMode {
        switch figures.lowercased() {
        case "crop": return .crop
        case "off":  return .off
        default:
            warn("Unknown figure mode '\(figures)'; using crop")
            return .crop
        }
    }

    private func parsePageRange() throws -> PageRange? {
        guard let p = pages else { return nil }
        guard let range = PageRange(string: p) else {
            fputs("visionmd: invalid --pages range: '\(p)'\n", stderr)
            throw ExitCode(1)
        }
        return range
    }

    private func resolvedLanguages() -> [Locale.Language] {
        guard let l = lang else { return [] }
        return l.split(separator: ",")
                .map { Locale.Language(identifier: String($0).trimmingCharacters(in: .whitespaces)) }
    }

    // MARK: URL resolution

    private func resolveOutputURL(stem: String) -> URL {
        if let o = output {
            return URL(fileURLWithPath: o)
        }
        let inputParent = URL(fileURLWithPath: input).deletingLastPathComponent()
        return inputParent.appendingPathComponent("\(stem).md")
    }

    private func resolveAssetsDirURL(outputURL: URL, stem: String) -> URL {
        if let d = assetsDir {
            return URL(fileURLWithPath: d)
        }
        return outputURL.deletingLastPathComponent()
                        .appendingPathComponent("\(stem)_assets")
    }

    /// Relative path prefix from `base` dir to `target` dir ("" when equal,
    /// "name" when target is a direct child, absolute path as fallback).
    private func relativePrefix(from base: URL, to target: URL) -> String {
        let baseComps = base.standardizedFileURL.pathComponents
        let targetComps = target.standardizedFileURL.pathComponents
        if baseComps == targetComps { return "" }
        if targetComps.count == baseComps.count + 1,
           Array(targetComps.prefix(baseComps.count)) == baseComps {
            return targetComps.last!
        }
        // Not a simple child — build a ../-style relative path.
        var common = 0
        while common < min(baseComps.count, targetComps.count),
              baseComps[common] == targetComps[common] { common += 1 }
        let ups = Array(repeating: "..", count: baseComps.count - common)
        let downs = targetComps[common...]
        return (ups + downs).joined(separator: "/")
    }

    private func resolveJsonURL(outputURL: URL, stem: String) -> URL? {
        if let p = emitJsonPath {
            return URL(fileURLWithPath: p)
        }
        if emitJson {
            return outputURL.deletingLastPathComponent()
                            .appendingPathComponent("\(stem).ocr.json")
        }
        return nil
    }
}

// MARK: - Per-page pipeline options (Sendable bundle)

struct ProcessOptions: Sendable {
    let languages: [Locale.Language]
    let level: RecognitionLevel
    let textLayerMode: TextLayerMode
    let tableMode: TableMode
    let figureMode: FigureMode
    let minFigureArea: Double
    let minConfidence: Float
    let assetsDirURL: URL
    let hashAssets: Bool
}

// MARK: - Per-page pipeline

enum Pipeline {

    static func process(_ page: RasterizedPage, options: ProcessOptions) async throws -> PageResult {
        // Stage 2: Vision recognition
        let raw = try await Recognizer.recognize(
            page.image,
            languages: options.languages,
            level: options.level
        )

        // Stage 3: Layout resolution
        var elements = LayoutResolver.resolve(
            raw,
            page: page,
            tableMode: options.tableMode
        )

        // Hybrid text-layer reconciliation (§5.1)
        if options.textLayerMode != .off {
            elements = HybridReconciler.merge(elements, pdfTextLayer: page.pdfTextLayer)
        }

        // Stage 5: Figure extraction
        if options.figureMode == .crop {
            let occupied = elements.map(\.region)
            let figOptions = FigureExtractor.Options(
                assetsURL: options.assetsDirURL,
                minFigureArea: options.minFigureArea,
                hashAssets: options.hashAssets
            )
            let figures = FigureExtractor.extract(
                page: page,
                occupied: occupied,
                options: figOptions
            )
            elements.append(contentsOf: figures)
            // Re-sort after adding figures, then associate captions.
            elements = LayoutResolver.order(elements, page: page)
            FigureExtractor.associateCaptions(&elements)
        }

        return PageResult(
            index: page.index,
            pixelSize: page.pixelSize,
            elements: elements
        )
    }
}
