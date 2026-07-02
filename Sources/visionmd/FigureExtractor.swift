import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Stage 5: Figure / image extraction
//
// v0.1 strategy: crop non-text regions from the high-DPI raster.
// This captures raster photos, CAD line-work, stamps, and vector diagrams uniformly.

enum FigureExtractor {

    struct Options: Sendable {
        let assetsURL: URL
        let minFigureArea: Double   // fraction of page area
        let hashAssets: Bool
    }

    // MARK: Public entry point

    static func extract(
        page: RasterizedPage,
        occupied: [CGRect],         // internal-normalized rects (top-left origin)
        options: Options
    ) -> [DocElement] {
        guard !page.image.width.isZero else { return [] }

        // Add small padding around occupied rects to avoid slicing text baselines.
        let padded = occupied.map { $0.insetBy(dx: -0.005, dy: -0.005) }

        let candidates = Geometry.negativeSpace(
            pageNorm: .unit,
            minus: padded,
            minArea: CGFloat(options.minFigureArea)
        )

        var results: [DocElement] = []
        for (m, regionNorm) in candidates.enumerated() {
            let pixRect = Geometry.toPixels(regionNorm, pixelSize: page.pixelSize)

            guard let crop = page.image.cropping(to: pixRect.integral) else { continue }
            guard !ImageStats.isNearBlank(crop) else {
                verbose("Page \(page.index + 1) fig \(m + 1): skipped (near-blank)")
                continue
            }

            let filename = figureFilename(page: page.index, fig: m, crop: crop, options: options)
            let destURL = options.assetsURL.appendingPathComponent(filename)

            do {
                try writePNG(crop, to: destURL)
                verbose("Page \(page.index + 1): extracted figure → \(filename)")
            } catch {
                warn("Page \(page.index + 1): could not write figure \(filename): \(error)")
                continue
            }

            // Store a relative path from the assets directory root.
            let relPath = "assets/\(filename)"
            results.append(.figure(assetRelPath: relPath, region: regionNorm, caption: nil))
        }
        return results
    }

    // MARK: Caption association

    /// Scan elements after layout ordering: if a short paragraph immediately follows
    /// a figure and is within 1.5 normalised line heights, assign it as caption.
    static func associateCaptions(_ elements: inout [DocElement]) {
        // Use explicit index management; we remove elements during iteration so
        // a fixed `for i in 0..<count` range would go out-of-bounds after removal.
        var i = 0
        while i < elements.count {
            guard case .figure(let path, let figRect, nil) = elements[i] else {
                i += 1
                continue
            }
            let captionMaxY = figRect.maxY + figRect.height * 0.15   // ~1.5 line heights below

            // Look at the next few elements for a candidate caption.
            var j = i + 1
            while j < min(i + 4, elements.count) {
                if case .paragraph(let text, let pRect, _) = elements[j] {
                    guard pRect.minY <= captionMaxY else { break }
                    if text.count <= 200 {  // captions are short
                        elements[i] = .figure(assetRelPath: path, region: figRect, caption: text)
                        elements.remove(at: j)  // safe: we break immediately after
                        break
                    }
                    j += 1
                } else {
                    break   // non-paragraph between figure and caption → stop looking
                }
            }
            i += 1
        }
    }

    // MARK: Filename helpers

    private static func figureFilename(
        page: Int,
        fig: Int,
        crop: CGImage,
        options: Options
    ) -> String {
        let base = "page-\(page + 1)-fig-\(fig + 1)"
        if options.hashAssets {
            let hash = imageHash(crop)
            return "\(base)-\(hash).png"
        }
        return "\(base).png"
    }

    private static func imageHash(_ image: CGImage) -> String {
        // Very fast approximate hash: sum of corner pixel values.
        // Replace with SHA-256 of PNG bytes for true content addressing.
        var h: UInt64 = 0
        let w = image.width, hh = image.height
        let corners = [(0, 0), (w - 1, 0), (0, hh - 1), (w - 1, hh - 1),
                       (w / 2, hh / 2)]
        let bpp = 4  // RGBA
        if let ctx = CGContext(data: nil, width: w, height: hh,
                               bitsPerComponent: 8, bytesPerRow: w * bpp,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: hh))
            if let data = ctx.data {
                for (cx, cy) in corners {
                    guard cx >= 0, cx < w, cy >= 0, cy < hh else { continue }
                    let offset = (cy * w + cx) * bpp
                    let ptr = data.assumingMemoryBound(to: UInt8.self)
                    h = h &* 31 &+ UInt64(ptr[offset]) &+ UInt64(ptr[offset + 1]) &+ UInt64(ptr[offset + 2])
                }
            }
        }
        return String(format: "%08x", h & 0xFFFF_FFFF)
    }

    // MARK: PNG writing

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1, nil
        ) else {
            throw VisionMDError.imageWriteFailed(url)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw VisionMDError.imageWriteFailed(url)
        }
    }
}

// MARK: - Image statistics

enum ImageStats {

    /// True if the image is near-blank (almost all pixels close to white).
    static func isNearBlank(_ image: CGImage) -> Bool {
        let sampleW = min(image.width, 64)
        let sampleH = min(image.height, 64)
        guard sampleW > 0, sampleH > 0 else { return true }

        guard let ctx = CGContext(
            data: nil, width: sampleW, height: sampleH,
            bitsPerComponent: 8, bytesPerRow: sampleW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: sampleW, height: sampleH))

        guard let data = ctx.data else { return false }
        let ptr = data.assumingMemoryBound(to: UInt8.self)
        let pixelCount = sampleW * sampleH

        var nonWhiteCount = 0
        for i in 0..<pixelCount {
            let base = i * 4
            let r = Int(ptr[base]), g = Int(ptr[base + 1]), b = Int(ptr[base + 2])
            if r < 230 || g < 230 || b < 230 { nonWhiteCount += 1 }
        }

        let nonWhiteFraction = Double(nonWhiteCount) / Double(pixelCount)
        return nonWhiteFraction < 0.01   // Less than 1% non-white pixels → blank
    }
}

extension Int {
    fileprivate var isZero: Bool { self == 0 }
}
