import ArgumentParser
import Foundation

// MARK: - CLI enum conformances
//
// The mode enums are String-raw CaseIterable (Model.swift); ArgumentParser's
// RawRepresentable conformance makes invalid values hard errors that list the
// allowed values in the message.

extension RecognitionLevel: ExpressibleByArgument {}
extension TextLayerMode: ExpressibleByArgument {}
extension TableMode: ExpressibleByArgument {}
extension FigureMode: ExpressibleByArgument {}

// MARK: - Entry point

@main
struct VisionMD: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "visionmd",
        abstract: "PDF/image → Markdown with tables and figures, via Apple Vision.",
        version: VisionMDVersion.string
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

    @Option(help: "Recognition level (only affects the macOS 15 fallback text path).")
    var level: RecognitionLevel = .accurate

    @Option(help: "Page range, e.g. 1-5,8,11-. Default: all")
    var pages: String?

    @Option(name: .customLong("text-layer"), help: "PDF text-layer mode.")
    var textLayer: TextLayerMode = .hybrid

    @Option(help: "Table mode.")
    var tables: TableMode = .native

    @Option(help: "Figure mode.")
    var figures: FigureMode = .crop

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

    @Flag(name: .customLong("keep-page-furniture"),
          help: "Keep repeated page headers/footers instead of removing them.")
    var keepPageFurniture: Bool = false

    @Flag(help: "Suppress informational output.")
    var quiet: Bool = false

    @Flag(help: "Verbose logging.")
    var verbose: Bool = false

    // MARK: Run

    func run() async throws {
        // Logging level
        if quiet   { globalLogLevel = .quiet }
        if verbose { globalLogLevel = .verbose }

        // OS guard: native table detection requires macOS 26.
        if tables == .native, #unavailable(macOS 26) {
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

        let options = ConversionOptions(
            dpi: dpi,
            languages: resolvedLanguages(),
            level: level,
            pageRange: try parsePageRange(),
            textLayerMode: textLayer,
            tableMode: tables,
            figureMode: figures,
            minFigureArea: minFigureArea,
            minConfidence: Float(minConfidence),
            emitHeadings: !noHeadings,
            pageRules: pageRules,
            frontMatter: frontMatter,
            keepPageFurniture: keepPageFurniture,
            hashAssets: hashAssets,
            outputURL: outputURL,
            assetsDirURL: assetsDirURL,
            jsonURL: jsonURL
        )

        let result: ConversionResult
        do {
            result = try await ConversionJob(inputURL: inputURL, options: options).execute()
        } catch let error as ConversionError {
            fputs("visionmd: \(error)\n", stderr)
            throw ExitCode(1)
        }

        // Write Markdown.
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try result.markdown.write(to: outputURL, atomically: true, encoding: .utf8)
        log("Markdown written → \(outputURL.path) (\(result.markdown.utf8.count) bytes)")

        // Write sidecar JSON (if requested).
        if let jsonDest = jsonURL {
            try Sidecar.write(result.sidecar, to: jsonDest)
        }

        if result.partialFailure { throw ExitCode(3) }
    }

    // MARK: Option parsing helpers

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

        // Mixed-source reconciliation: swap OCR text for PDF-layer text where
        // the SourcePolicy accepts it (Phase 2).
        elements = MixedSourceReconciler.reconcile(elements, page: page, mode: options.textLayerMode)

        // Table header detection (Phase 5.2) — needs reconciled cell text.
        elements = TableRefiner.refineHeaders(elements, page: page)

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
