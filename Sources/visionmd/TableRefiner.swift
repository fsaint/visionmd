import CoreGraphics
import Foundation

// MARK: - Table refinement (Phase 5.2)
//
// Header detection: today row 0 was unconditionally the header. Detect
// instead; headerless tables render with an empty GFM header row and get
// header_detected: false in the sidecar.

enum TableRefiner {

    /// Row 0 is a header when either positive signal fires:
    ///  - digital pages: ≥ half of row 0's non-empty cells are covered by a
    ///    bold or larger-than-body positioned run;
    ///  - grid shape: row 0 is entirely non-numeric (a numeric label row is
    ///    almost certainly data — the "headerless numeric grid" case).
    /// Deliberately conservative: a plain-styled non-numeric row 0 stays a
    /// header (demoting real headers is worse than keeping a weak one).
    static func detectHeader(
        _ model: TableModel,
        runs: [PositionedTextRun],
        bodyFontSize: CGFloat?
    ) -> Bool {
        guard model.rowCount >= 2 else { return false }   // one row can't be header+data

        // --- Font rule (digital only) ---
        // Merged row-0 cells vote once (they appear once in cells[]).
        if !runs.isEmpty {
            let votable = model.cells.filter {
                $0.row == 0 && $0.region != nil
                    && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty
            }
            if !votable.isEmpty {
                let styled = votable.filter { cell in
                    guard let rect = cell.region else { return false }
                    let expanded = rect.insetBy(dx: -0.005, dy: -0.005)
                    return runs.contains { run in
                        guard expanded.contains(run.rect.center) else { return false }
                        if run.isBold { return true }
                        if let body = bodyFontSize, run.fontSize > body + 0.5 { return true }
                        return false
                    }
                }
                if Float(styled.count) / Float(votable.count) >= 0.5 { return true }
            }
        }

        // --- Grid-shape rule (any page class) ---
        // Row 0 containing numeric cells is a data row, not a header.
        let grid = model.denseGrid()
        guard let row0 = grid.first else { return false }
        let row0NonEmpty = row0.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !row0NonEmpty.isEmpty else { return false }
        return row0NonEmpty.allSatisfy { !isNumeric($0) }
    }

    /// Apply header detection to all tables on a page.
    static func refineHeaders(_ elements: [DocElement], page: RasterizedPage) -> [DocElement] {
        elements.map { el in
            guard case .table(let model, let region, let conf) = el else { return el }
            var refined = model
            refined.headerDetected = detectHeader(
                model,
                runs: page.positionedRuns,
                bodyFontSize: page.fontInfo?.bodyFontSize
            )
            return .table(refined, region: region, confidence: conf)
        }
    }

    /// Shared numeric-cell check (moved from TableRenderer so header
    /// detection and column alignment agree on what "numeric" means).
    static func isNumeric(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        return Double(t.filter { $0 != "," && $0 != "%" && $0 != "$" }) != nil
    }
}
