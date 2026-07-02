import CoreGraphics
import Foundation

// MARK: - Stage 4: Element → Markdown mapping

enum MarkdownRenderer {

    struct Options: Sendable {
        let minConfidence: Float
        let emitHeadings: Bool
        let pageRules: Bool
    }

    // MARK: Page rendering

    static func renderPage(
        _ result: PageResult,
        options: Options
    ) -> String {
        var parts: [String] = []

        for element in result.elements {
            let md = renderElement(element, pageIndex: result.index, options: options)
            if !md.isEmpty { parts.append(md) }
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: Element dispatch

    static func renderElement(
        _ element: DocElement,
        pageIndex: Int,
        options: Options
    ) -> String {
        switch element {
        case .heading(let level, let text, _, _):
            guard options.emitHeadings else {
                return escapeParagraph(text)
            }
            let hashes = String(repeating: "#", count: max(1, min(level, 6)))
            return "\(hashes) \(text)"

        case .paragraph(let text, _, let conf):
            var md = escapeParagraph(text)
            if conf < options.minConfidence {
                md = "> ⚠️ Low-confidence text (\(String(format: "%.2f", conf)))\n\n" + md
            }
            return md

        case .list(let ordered, let items, _, _):
            return renderList(ordered: ordered, items: items)

        case .table(let model, _, let conf):
            let id = "t_p\(pageIndex + 1)"
            return TableRenderer.markdown(model, id: id, minConf: options.minConfidence, tableConf: conf)

        case .figure(let relPath, _, let caption):
            let alt = caption ?? "figure"
            var md = "![\(alt)](\(relPath))"
            if let cap = caption {
                md += "\n\n*\(cap)*"
            }
            return md

        case .barcode(let payload, let symbology, _):
            return "`[barcode:\(symbology)] \(payload)`"
        }
    }

    // MARK: Helpers

    private static func escapeParagraph(_ text: String) -> String {
        // Collapse internal newlines within a paragraph to spaces.
        let collapsed = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // Escape stray Markdown control chars at line starts that are OCR artifacts.
        return escapedLineStart(collapsed)
    }

    private static func escapedLineStart(_ s: String) -> String {
        guard let first = s.first else { return s }
        // Characters that start Markdown constructs: # - > | digit+period
        let triggers: Set<Character> = ["#", "-", ">", "|", "+", "*"]
        if triggers.contains(first) {
            return "\\" + s
        }
        // Digit(s) followed by period (ordered list): "1. text" → "1\. text"
        if first.isNumber {
            let numPart = s.prefix(while: { $0.isNumber })
            let rest = s.dropFirst(numPart.count)
            if rest.hasPrefix(".") { return numPart + "\\" + rest }
        }
        return s
    }

    private static func renderList(ordered: Bool, items: [String]) -> String {
        items.enumerated().map { idx, item in
            let prefix = ordered ? "\(idx + 1)." : "-"
            return "\(prefix) \(item)"
        }.joined(separator: "\n")
    }
}

// MARK: - Table → Markdown / HTML

enum TableRenderer {

    static func markdown(
        _ t: TableModel,
        id: String,
        minConf: Float,
        tableConf: Float
    ) -> String {
        var out = ""

        // Low-confidence callout
        if tableConf < minConf {
            out += "> ⚠️ Low-confidence table (\(String(format: "%.2f", tableConf)))"
                + " — flagged for re-OCR. Sidecar id \(id).\n\n"
        }

        if t.hasMerges {
            out += "<!-- visionmd:complex-table id=\(id) -->\n"
            out += htmlTable(t, id: id)
        } else {
            out += pipeTable(t)
        }

        return out
    }

    // MARK: Pipe table (simple grid, no merges)

    private static func pipeTable(_ t: TableModel) -> String {
        guard t.rowCount > 0, t.colCount > 0 else { return "" }
        let grid = t.denseGrid()

        // Detect numeric columns for right-alignment.
        var numericCol = Array(repeating: true, count: t.colCount)
        for row in grid.dropFirst() {
            for (c, cell) in row.enumerated() {
                if !isNumeric(cell) { numericCol[c] = false }
            }
        }

        var lines: [String] = []

        // Header row (row 0)
        let header = grid.first ?? Array(repeating: "", count: t.colCount)
        lines.append("| " + header.map(escapeCell).joined(separator: " | ") + " |")

        // Separator row
        let sep = (0..<t.colCount).map { c in numericCol[c] ? "--:" : "---" }
        lines.append("| " + sep.joined(separator: " | ") + " |")

        // Data rows
        for row in grid.dropFirst() {
            // Pad or truncate to colCount
            var cells = row
            while cells.count < t.colCount { cells.append("") }
            cells = Array(cells.prefix(t.colCount))
            lines.append("| " + cells.map(escapeCell).joined(separator: " | ") + " |")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: HTML table (merged cells)

    private static func htmlTable(_ t: TableModel, id: String) -> String {
        // Build a coverage map to handle spans.
        var covered = Set<String>()

        var html = "<table id=\"\(id)\">\n"
        for r in 0..<t.rowCount {
            html += "  <tr>\n"
            for c in 0..<t.colCount {
                let key = "\(r),\(c)"
                if covered.contains(key) { continue }

                if let cell = t.cells.first(where: { $0.row == r && $0.col == c }) {
                    let rs = cell.rowSpan > 1 ? " rowspan=\"\(cell.rowSpan)\"" : ""
                    let cs = cell.colSpan > 1 ? " colspan=\"\(cell.colSpan)\"" : ""
                    let tag = r == 0 ? "th" : "td"
                    let text = cell.text
                        .replacingOccurrences(of: "\n", with: "<br>")
                        .replacingOccurrences(of: "<", with: "&lt;")
                        .replacingOccurrences(of: ">", with: "&gt;")
                    html += "    <\(tag)\(rs)\(cs)>\(text)</\(tag)>\n"

                    // Mark covered cells
                    for dr in 0..<cell.rowSpan {
                        for dc in 0..<cell.colSpan {
                            covered.insert("\(r + dr),\(c + dc)")
                        }
                    }
                } else {
                    html += "    <td></td>\n"
                }
            }
            html += "  </tr>\n"
        }
        html += "</table>\n"
        return html
    }

    // MARK: Helpers

    static func escapeCell(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|")
         .replacingOccurrences(of: "\n", with: "<br>")
         .trimmingCharacters(in: .whitespaces)
    }

    private static func isNumeric(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return true }
        return Double(t.filter { $0 != "," && $0 != "%" && $0 != "$" }) != nil
    }
}

// MARK: - Output assembly

enum Assembler {

    struct Options: Sendable {
        let frontMatter: Bool
        let pageComments: Bool
        let pageRules: Bool
        let sourceFile: String
        let dpi: Double
    }

    static func assembleMarkdown(
        results: [PageResult],
        markdownOptions: MarkdownRenderer.Options,
        assemblyOptions: Options
    ) -> String {
        var out = ""

        if assemblyOptions.frontMatter {
            let meanConf = results.isEmpty ? 0.0 :
                results.map(\.meanConfidence).reduce(0, +) / Float(results.count)
            out += "---\n"
            out += "source: \(assemblyOptions.sourceFile)\n"
            out += "pages: \(results.count)\n"
            out += "generated_by: visionmd 0.1\n"
            out += "dpi: \(Int(assemblyOptions.dpi))\n"
            out += "mean_confidence: \(String(format: "%.2f", meanConf))\n"
            out += "---\n\n"
        }

        let sorted = results.sorted { $0.index < $1.index }
        for (i, result) in sorted.enumerated() {
            if i > 0 {
                out += "\n\n<!-- page \(result.index + 1) -->\n\n"
                if assemblyOptions.pageRules { out += "---\n\n" }
            }
            let pageMarkdown = MarkdownRenderer.renderPage(result, options: markdownOptions)
            out += pageMarkdown
        }

        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }
}
