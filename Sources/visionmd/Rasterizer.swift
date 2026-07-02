import CoreGraphics
import Foundation
import PDFKit
import UniformTypeIdentifiers

// MARK: - Stage 1: Input loading and PDF rasterization

enum Rasterizer {

    /// Maximum pixel dimension on the longest edge (to prevent OOM on large-format sheets).
    static let maxPixelDimension: CGFloat = 12_000

    // MARK: Public entry point

    /// Load a PDF, single image, or directory of images and return rasterized pages.
    /// Pages are 0-indexed; `pageRange` filters by 1-indexed page numbers.
    static func load(
        _ path: String,
        dpi: Double,
        pageRange: PageRange?
    ) throws -> [RasterizedPage] {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw VisionMDError.badInput("File not found: \(path)")
        }

        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            return try loadPDF(url: url, dpi: dpi, pageRange: pageRange)
        } else if isImageExtension(ext) {
            let page = try rasterizeImage(url: url, index: 0, dpi: dpi)
            if let range = pageRange, !range.contains(pageNumber: 1) { return [] }
            return [page]
        } else {
            // Directory of images
            var stat: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &stat)
            if stat.boolValue {
                return try loadImageDirectory(url: url, dpi: dpi, pageRange: pageRange)
            }
            throw VisionMDError.badInput("Unsupported input: \(path)")
        }
    }

    // MARK: PDF loading

    private static func loadPDF(url: URL, dpi: Double, pageRange: PageRange?) throws -> [RasterizedPage] {
        guard let doc = PDFDocument(url: url) else {
            throw VisionMDError.badInput("Cannot open PDF: \(url.path)")
        }
        let pageCount = doc.pageCount
        log("PDF has \(pageCount) page(s): \(url.lastPathComponent)")

        var pages: [RasterizedPage] = []
        for i in 0..<pageCount {
            let pageNumber = i + 1  // 1-indexed for range checks
            if let range = pageRange, !range.contains(pageNumber: pageNumber) { continue }

            guard let pdfPage = doc.page(at: i) else {
                warn("Skipping page \(pageNumber): PDFKit returned nil")
                continue
            }
            // Wrap each page in an autoreleasepool so PDFKit graphics contexts,
            // attributedString caches, and JBIG2 decoder state are released
            // promptly. Without this, 50+ page PDFs accumulate enough ObjC
            // objects to trigger a SIGSEGV in CoreAnalytics/CoreGraphics.
            let page = try autoreleasepool {
                try rasterizePDFPage(pdfPage: pdfPage, index: i, dpi: dpi)
            }
            pages.append(page)
        }
        return pages
    }

    private static func rasterizePDFPage(
        pdfPage: PDFPage,
        index: Int,
        dpi: Double
    ) throws -> RasterizedPage {
        let mediaBox = pdfPage.bounds(for: .mediaBox)
        let scale = CGFloat(dpi) / 72.0

        var pixelW = mediaBox.width  * scale
        var pixelH = mediaBox.height * scale

        // Clamp to max pixel dimension while preserving aspect ratio.
        let longest = max(pixelW, pixelH)
        if longest > maxPixelDimension {
            let ratio = maxPixelDimension / longest
            pixelW *= ratio
            pixelH *= ratio
            warn("Page \(index + 1): clamped from \(Int(longest)) to \(Int(maxPixelDimension)) px (longest edge)")
        }

        let w = Int(pixelW.rounded())
        let h = Int(pixelH.rounded())

        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw VisionMDError.rasterizationFailed(index)
        }

        // White background
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // PDFPage.draw(with:to:) handles the PDF→screen Y-flip internally.
        // We only scale for DPI; adding our own flip causes horizontal mirroring.
        let scaleX = CGFloat(w) / mediaBox.width
        let scaleY = CGFloat(h) / mediaBox.height
        ctx.scaleBy(x: scaleX, y: scaleY)

        pdfPage.draw(with: .mediaBox, to: ctx)

        guard let image = ctx.makeImage() else {
            throw VisionMDError.rasterizationFailed(index)
        }

        let textLayer = extractTextLayer(pdfPage: pdfPage)
        let fontInfo = PDFStructureExtractor.extractFontInfo(from: pdfPage)
        verbose("Page \(index + 1): \(w)×\(h) px, text layer \(textLayer?.isEmpty == false ? "present" : "absent")")

        return RasterizedPage(
            index: index,
            image: image,
            pixelSize: CGSize(width: w, height: h),
            pointSize: CGSize(width: mediaBox.width, height: mediaBox.height),
            dpi: CGFloat(dpi),
            pdfTextLayer: textLayer,
            fontInfo: fontInfo
        )
    }

    // MARK: Single image

    private static func rasterizeImage(url: URL, index: Int, dpi: Double) throws -> RasterizedPage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw VisionMDError.badInput("Cannot load image: \(url.path)")
        }
        let pixelSize = CGSize(width: image.width, height: image.height)
        // Images don't have a PDF point size; approximate from pixels at given DPI.
        let ptW = CGFloat(image.width)  / CGFloat(dpi) * 72
        let ptH = CGFloat(image.height) / CGFloat(dpi) * 72
        return RasterizedPage(
            index: index,
            image: image,
            pixelSize: pixelSize,
            pointSize: CGSize(width: ptW, height: ptH),
            dpi: CGFloat(dpi),
            pdfTextLayer: nil,
            fontInfo: nil
        )
    }

    // MARK: Image directory

    private static func loadImageDirectory(
        url: URL,
        dpi: Double,
        pageRange: PageRange?
    ) throws -> [RasterizedPage] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.nameKey])
        let images = contents
            .filter { isImageExtension($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        log("Directory has \(images.count) image(s)")
        var pages: [RasterizedPage] = []
        for (i, imgURL) in images.enumerated() {
            let pageNumber = i + 1
            if let range = pageRange, !range.contains(pageNumber: pageNumber) { continue }
            let page = try rasterizeImage(url: imgURL, index: i, dpi: dpi)
            pages.append(page)
        }
        return pages
    }

    // MARK: Helpers

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "bmp"]

    private static func isImageExtension(_ ext: String) -> Bool {
        imageExtensions.contains(ext)
    }

    /// Extract the embedded text layer from a PDFPage. Returns nil if absent or garbled.
    static func extractTextLayer(pdfPage: PDFPage) -> String? {
        guard let text = pdfPage.string, !text.isEmpty else { return nil }
        // Heuristic: if >10% of characters are non-printable/replacement,
        // treat the text layer as garbled OCR output and ignore it.
        let total = text.unicodeScalars.count
        let garbage = text.unicodeScalars.filter { $0.value == 0xFFFD || $0.value < 32 }.count
        guard total > 0, CGFloat(garbage) / CGFloat(total) < 0.1 else { return nil }
        return text
    }
}
