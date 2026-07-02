import CoreGraphics
import Foundation

// MARK: - Document-level refinement (Phase 4)
//
// Operates on [PageResult] after per-page processing, before assembly.

enum DocumentRefiner {

    // MARK: 4.2 Repeated header/footer removal

    /// Text repeated at the same position near the top/bottom of most pages is
    /// page furniture (letterheads, "Printed on…", page footers) → drop it.
    ///
    /// Fingerprint = digit-stripped normalized text + rounded region center.
    /// Furniture = fingerprint present on ≥ 60% of pages (minimum 3 pages)
    /// within the top 12% or bottom 10% of the page.
    static func removePageFurniture(_ results: [PageResult]) -> [PageResult] {
        let pageCount = results.count
        guard pageCount >= 3 else { return results }
        let threshold = max(3, Int((Double(pageCount) * 0.6).rounded(.up)))

        // Count distinct pages per fingerprint.
        var pagesPerFingerprint: [String: Set<Int>] = [:]
        for result in results {
            for el in result.elements {
                guard let fp = furnitureFingerprint(el) else { continue }
                pagesPerFingerprint[fp, default: []].insert(result.index)
            }
        }

        let furniture = Set(
            pagesPerFingerprint.filter { $0.value.count >= threshold }.map(\.key)
        )
        guard !furniture.isEmpty else { return results }

        var dropped = 0
        let refined = results.map { result in
            let kept = result.elements.filter { el in
                guard let fp = furnitureFingerprint(el) else { return true }
                let isFurniture = furniture.contains(fp)
                if isFurniture { dropped += 1 }
                return !isFurniture
            }
            return PageResult(index: result.index, pixelSize: result.pixelSize, elements: kept)
        }
        if dropped > 0 {
            verbose("Removed \(dropped) repeated header/footer element(s) across \(pageCount) pages")
        }
        return refined
    }

    /// Fingerprint for furniture candidates; nil when the element can't be furniture.
    static func furnitureFingerprint(_ el: DocElement) -> String? {
        let text: String
        switch el {
        case .paragraph(let t, _, _), .heading(_, let t, _, _):
            text = t
        default:
            return nil   // figures/tables/lists are never dropped
        }

        let region = el.region
        // Furniture zone: top 12% or bottom 10% of the page.
        let inHeaderZone = region.midY <= 0.12
        let inFooterZone = region.midY >= 0.90
        guard inHeaderZone || inFooterZone else { return nil }

        // Digit-stripped so "Page 1"/"Page 2" and dates share a fingerprint.
        let normalized = TextSimilarity.normalize(text)
            .filter { !$0.isNumber }
            .trimmingCharacters(in: .whitespaces)
        guard normalized.count >= 3 else { return nil }

        // Rounded position (2% grid) so slight bbox jitter still matches.
        let cx = (region.midX * 50).rounded() / 50
        let cy = (region.midY * 50).rounded() / 50
        return "\(normalized)|\(cx)|\(cy)"
    }
}
