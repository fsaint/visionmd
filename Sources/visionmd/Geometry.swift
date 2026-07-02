import CoreGraphics
import Foundation

// MARK: - Coordinate system conversions
//
// Three spaces are in play:
//   1. Vision normalized  [0,1]×[0,1]  origin BOTTOM-LEFT  Y-up
//   2. Pixel space        [0,W]×[0,H]  origin TOP-LEFT     Y-down
//   3. PDF point space    [0,ptW]×[0,ptH] origin BOTTOM-LEFT Y-up
//
// Canonical internal space used throughout the pipeline:
//   Top-left normalized  [0,1]×[0,1]  origin TOP-LEFT  Y-down
//   (This is also what sidecar bbox_norm uses.)
//
// Convert Vision → internal once in Recognizer; never flip ad hoc elsewhere.

enum Geometry {

    // MARK: Vision ↔ internal

    /// Convert a rect from Vision space (bottom-left origin, Y-up) to
    /// internal space (top-left origin, Y-down), both normalized [0,1].
    static func visionToInternal(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX,
               y: 1.0 - r.maxY,
               width: r.width,
               height: r.height)
    }

    /// Convert a rect from internal space back to Vision space.
    static func internalToVision(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX,
               y: 1.0 - r.maxY,
               width: r.width,
               height: r.height)
    }

    // MARK: Internal ↔ pixels

    /// Scale an internal-normalized rect to pixel coordinates.
    static func toPixels(_ r: CGRect, pixelSize: CGSize) -> CGRect {
        CGRect(x:      r.minX  * pixelSize.width,
               y:      r.minY  * pixelSize.height,
               width:  r.width  * pixelSize.width,
               height: r.height * pixelSize.height)
    }

    /// Scale a pixel rect back to internal-normalized coords.
    static func fromPixels(_ r: CGRect, pixelSize: CGSize) -> CGRect {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return .zero }
        return CGRect(x:      r.minX  / pixelSize.width,
                      y:      r.minY  / pixelSize.height,
                      width:  r.width  / pixelSize.width,
                      height: r.height / pixelSize.height)
    }

    // MARK: Internal ↔ PDF points

    /// Convert internal-normalized to PDF point space (bottom-left origin).
    static func toPDFPoints(_ r: CGRect, pointSize: CGSize) -> CGRect {
        let flipped = internalToVision(r)
        return CGRect(x:      flipped.minX  * pointSize.width,
                      y:      flipped.minY  * pointSize.height,
                      width:  flipped.width  * pointSize.width,
                      height: flipped.height * pointSize.height)
    }

    // MARK: Overlap / area

    static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        a.intersection(b).area
    }

    /// True if `inner` is substantially inside `outer` (> threshold fraction overlap).
    static func isContained(_ inner: CGRect, within outer: CGRect, threshold: CGFloat = 0.8) -> Bool {
        guard inner.area > 0 else { return false }
        return intersectionArea(inner, outer) / inner.area >= threshold
    }

    // MARK: Negative space (for figure detection)

    /// Return axis-aligned candidate figure regions in internal-normalized coords
    /// by scanning horizontal bands of the page not covered by occupied rects.
    ///
    /// This is a simplified band-scan approach: divides the page into N horizontal
    /// strips and finds contiguous unoccupied strip runs exceeding minArea.
    static func negativeSpace(
        pageNorm: CGRect = .unit,
        minus occupied: [CGRect],
        minArea: CGFloat
    ) -> [CGRect] {
        let strips = 200
        let stripH = pageNorm.height / CGFloat(strips)
        var inFigure = false
        var figStart = pageNorm.minY
        var results: [CGRect] = []

        for i in 0..<strips {
            let y = pageNorm.minY + CGFloat(i) * stripH
            let band = CGRect(x: pageNorm.minX, y: y, width: pageNorm.width, height: stripH)
            let isCovered = occupied.contains { band.intersects($0.insetBy(dx: 0, dy: -0.001)) }

            if !isCovered && !inFigure {
                inFigure = true
                figStart = y
            } else if isCovered && inFigure {
                inFigure = false
                let candidate = CGRect(x: pageNorm.minX,
                                       y: figStart,
                                       width: pageNorm.width,
                                       height: y - figStart)
                if candidate.area >= minArea {
                    results.append(candidate)
                }
            }
        }
        if inFigure {
            let candidate = CGRect(x: pageNorm.minX,
                                   y: figStart,
                                   width: pageNorm.width,
                                   height: pageNorm.maxY - figStart)
            if candidate.area >= minArea { results.append(candidate) }
        }
        return results
    }
}

// MARK: - CGRect helpers

extension CGRect {
    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    var area: CGFloat { width * height }

    var center: CGPoint { CGPoint(x: midX, y: midY) }

    func contains(fraction other: CGRect) -> Bool {
        Geometry.isContained(other, within: self)
    }
}
