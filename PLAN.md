# visionmd Improvement Plan

Goal: the most **consistent** and **effective** PDF → Markdown converter using only
local Apple frameworks (Vision, PDFKit, CoreGraphics) — no LLM.

Core design decision: a **mixed approach**. Every page and every region is served by
one of two text sources — **PDF inspection** (PDFKit text layer, font runs, outline,
embedded images) or **OCR** (Vision) — chosen by explicit, testable criteria rather
than ad-hoc guesses. Structure (regions, tables, lists, reading order) always comes
from Vision; *text content* comes from whichever source the criteria select.
**Tables and tables of contents are priority element types** and get dedicated
phases.

This plan is written to be executed by Claude Code on a Mac (macOS 26 / Xcode 26,
`swift test` available). It is ordered so that every phase leaves the tree green and
each fix lands with its own test.

**Ground rules for the executor:**

- After every task: `swift build && swift test`. Never move on with a red tree.
- Every bug fix gets a regression test written **first** (red → green).
- Phase 0 creates the verification harness (fixtures + golden tests) that all later
  phases rely on. Do not skip it.
- Keep the existing architecture: Vision API isolated in `Recognizer.swift`,
  AppKit/PDFKit access isolated in `PDFStructureExtractor.swift` / `Rasterizer.swift`,
  one canonical coordinate space (top-left normalized) defined in `Geometry.swift`.

---

## The source-selection policy (design core — read before coding)

All routing decisions live in ONE new file, `SourcePolicy.swift`, as pure functions
over precomputed signals. Nothing else in the pipeline decides "layer vs OCR" on its
own. This is what makes the tool *consistent*: same inputs → same route → same output.

### Page-level classification

Computed once per page during Stage 1 (all PDFKit access up front; results are
Sendable and travel with `RasterizedPage`):

| Signal | How |
|---|---|
| `hasTextLayer` | `page.string` non-empty after garble check (fix in 1.5) |
| `garbleRatio` | U+FFFD + C0 controls (excluding `\n\r\t`) / total scalars |
| `layerCharCount` | character count of usable layer text |
| `fullPageImage` | page's `/Resources/XObject` contains an image covering ≥ 90% of the mediaBox |
| `hasFontInfo` | `attributedString` produced usable font runs |
| `isOCRLayer` | heuristic: full-page image AND text layer present (a scan that was previously OCR'd — its layer is *someone else's OCR*, trust accordingly) |
| `hasOutline` | document-level: `PDFDocument.outlineRoot` non-nil |

Page classes (enum `PageClass`):

- **`digital`** — `hasTextLayer && !fullPageImage && garbleRatio < 0.05`.
  Text source: PDF layer, per-region (see below). OCR text used only where the layer
  has no runs (stamps, rasterized headers).
- **`scannedWithOCRLayer`** — `fullPageImage && hasTextLayer`.
  Text source: compare per-region; prefer OCR unless the layer run agrees with
  Vision's transcript at ≥ 0.85 normalized similarity (then take the layer — it may
  carry better Unicode). Never trust layer font sizes for headings here.
- **`scanned`** — no usable layer. Text source: OCR only; headings via the
  line-height heuristic.
- **`mixed`** — usable layer but `fullPageImage` false and layer covers < 60% of
  Vision's recognized text (measured as char-count ratio). Route per-region.

### Region-level criteria (within `digital` / `mixed` pages)

For each Vision element region, collect positioned layer runs (see Phase 2) whose
center falls inside the region (tolerance ±0.5% page). Then:

1. **No runs found** → OCR text. (Region is a rasterized graphic with burned-in text.)
2. **Runs found** → candidate layer text = runs sorted (top→bottom, left→right),
   joined, normalized. Accept the layer text iff
   `abs(len(layer) - len(ocr)) / max(len(ocr),1) ≤ 0.4` **or** normalized similarity
   (case/space-insensitive Levenshtein on first 200 chars) ≥ 0.7.
   Otherwise keep OCR and log the disagreement at `verbose`.
3. **Digit-dense regions** (table cells, amounts: > 30% digits in either candidate) →
   tighten: accept layer text only on similarity ≥ 0.85, because a silent digit swap
   is worse than a flagged low-confidence OCR read. When rejected AND OCR confidence
   < threshold, mark the element `escalate` in the sidecar.

### Element-type policy summary

| Element | Structure from | Text from | Notes |
|---|---|---|---|
| Paragraph / heading | Vision | policy above | heading *level* from font runs when digital (Phase 4.1) |
| Table | Vision native tables | per-CELL policy (digit-dense rule) | Phase 5 |
| Table of contents | dedicated detector | PDF layer preferred (dot leaders + page numbers OCR poorly) | Phase 6 |
| List | Vision | policy above per item when feasible, else OCR | |
| Figure | negative space / XObjects | — | Phase 7 |
| Barcode | Vision | Vision | |

The policy module gets exhaustive unit tests: each rule above is a test case with
synthetic signals. This table is the spec; keep code and table in sync.

---

## Phase 0 — Test harness and baseline (do this first)

The current 34 tests are pure unit tests of heuristics. None of the known bugs
(broken image links, dead flags, text corruption, reading order) are caught by them.
Build the harness that will catch them.

### 0.1 Synthetic PDF fixtures generated in-test

PDFKit + CoreText can *create* PDFs, so fixtures are code, not binary blobs.
Add `Tests/visionmdTests/Fixtures/PDFFixtures.swift` with a builder that draws into a
`CGContext` PDF and returns a temp-file URL:

```swift
enum PDFFixture {
    /// Single page, one 24pt title + two 12pt body paragraphs (Helvetica).
    static func simpleArticle() -> URL
    /// Two-column page: 2 paragraphs per column + full-width footer at bottom.
    static func twoColumnWithFooter() -> URL
    /// 3 pages, identical header on each, paragraph broken mid-sentence with a
    /// hyphenated word across pages 2→3.
    static func multiPageWithHeaders() -> URL
    /// Page with filled gray rectangle (stand-in figure) + caption paragraph
    /// "Figure 1: Test diagram" below it.
    static func pageWithFigure() -> URL
    /// Page with a 3×4 ruled table: header row + 3 data rows, one numeric column.
    static func simpleTable() -> URL
    /// A table spanning two pages: header row repeats on page 2.
    static func crossPageTable() -> URL
    /// A "Contents" page: title + 8 dot-leader lines
    /// ("1. Introduction ........ 3"), nested entries indented, and a real
    /// PDFDocument outline matching the entries.
    static func tableOfContents() -> URL
    /// simpleArticle() rendered to a 300-DPI PNG and re-wrapped as image-only PDF
    /// (the "scanned" fixture; also return the bare PNG for image-input tests).
    static func scannedArticle() -> (pdf: URL, png: URL)
}
```

Use Core Text (`CTLineDraw`) so runs get real font metadata; use
`PDFDocument`+`PDFOutline` API to attach the outline in `tableOfContents()`.

### 0.2 End-to-end pipeline test helper

Factor the body of `VisionMD.run()` into `struct ConversionJob` (input URL + all
options) with `func execute() async throws -> ConversionResult` (markdown string,
page results, written asset URLs). `VisionMD.run()` becomes: parse options → build
job → execute → write. Tests call `ConversionJob` directly. Mark Vision-dependent
tests with an availability condition so the suite degrades gracefully.

### 0.3 Baseline invariant tests (write before touching pipeline code)

These encode the contracts later phases must satisfy; most fail today — that is the
point. Reference the fixing task in a comment:

1. **Asset links resolve** (`pageWithFigure`): every `![](path)` in the output exists
   on disk relative to the `.md`. (Fixed by 1.1.)
2. **`--tables off` emits no tables** (`simpleTable`). (Fixed by 1.2.)
3. **Reconciler never grows text** (`simpleArticle`): no output paragraph contains
   text of two source paragraphs. (Fixed by Phase 2.)
4. **Footer sorts last** (`twoColumnWithFooter`). (Fixed by Phase 3.)
5. **Digital table cells byte-exact** (`simpleTable`): every cell string matches what
   the fixture drew. (Fixed by Phase 5.)
6. **TOC is a list, not a table** (`tableOfContents`): output contains a nested list
   with page numbers, no pipe table, no `<table`. (Fixed by Phase 6.)
7. **Golden files** for each fixture under `Tests/visionmdTests/Golden/*.md`,
   compared exactly; regenerate via `REGENERATE_GOLDEN=1`. Lock goldens at end of
   Phase 3, extend at each later phase.

### 0.4 CI

`.github/workflows/ci.yml`: `swift build -c release` + `swift test` on `macos-26`
(or newest available macOS image, with Vision tests availability-gated).

**Exit criteria:** fixtures build; e2e helper runs `simpleArticle()`; invariant tests
exist (red ones annotated); CI added.

---

## Phase 1 — Correctness bug fixes (small, independent, high payoff)

### 1.1 Fix broken figure links
`FigureExtractor.swift:59` hardcodes `relPath = "assets/\(filename)"` but PNGs go to
the assets dir (default `<stem>_assets`, `VisionMD.swift:277`). Every image link in
every output is broken. Store the filename in the element; compute the rel path from
the real assets dir relative to the output `.md` in `MarkdownRenderer`. Unify README
(`figures/` vs `assets/` vs `<stem>_assets` — pick `<stem>_assets`).
Green: invariant (1).

### 1.2 Wire up dead options
`ProcessOptions.tableMode` is never read; `LayoutResolver.resolve` takes
`minConfidence` and ignores it. Pass `tableMode` into `resolve`; when `.off`, skip
table extraction AND the inside-table paragraph suppression. Delete the unused
`minConfidence` param. Green: invariant (2).

### 1.3 Fix HTML escaping order + `&`
`MarkdownRenderer.swift:192-194` inserts `<br>` then escapes `<`/`>` (destroying its
own tags) and never escapes `&`. Escape `&`,`<`,`>` first, then `\n`→`<br>`. Apply to
`TableRenderer.escapeCell` too. Unit test: `"a<b & c\nd"`.

### 1.4 Fix sidecar/markdown anchor mismatch
Sidecar IDs are `t_p1_1`, `t_p1_2` (`Sidecar.swift:89`); Markdown anchor is
`t_p\(pageIndex+1)` for all tables on a page (`MarkdownRenderer.swift:56`). Add
`enum ElementID` used by both; thread a per-page table counter through rendering.
Test: two complex tables on one page → distinct anchors matching sidecar.

### 1.5 Fix garble check counting whitespace as garbage
`Rasterizer.swift:192` counts scalars `< 32` including `\n\t` — short-line documents
lose their good text layer. Exclude `\n\r\t`; extract testable
`isUsableTextLayer(_:)`. This also feeds `garbleRatio` in the source policy.

### 1.6 Numeric sort for image directories
`Rasterizer.swift:165`: `page10 < page2`. Use `localizedStandardCompare`. Unit test.

### 1.7 Dedupe merged table cells
Iterating `vt.rows` (`Recognizer.swift:76`) yields a row-spanning cell once per row:
duplicate cells, double-counted confidence. Dedupe on
`(rowRange.lowerBound, columnRange.lowerBound)` in a pure, unit-tested helper.

### 1.8 Fix caption association geometry
`FigureExtractor.swift:78`: window is 15% of *figure height* (comment says "1.5 line
heights") and never checks the paragraph is below the figure. Absolute window
(`figRect.maxY + 0.03`), require below, prefer `^(Figure|Fig\.?|Table|Chart)\b`
matches. Unit tests for each case.

### 1.9 CLI enums via `ExpressibleByArgument`
Replace the four warn-and-default string parsers (`VisionMD.swift:206-245`) with the
existing raw-representable enums conforming to `ExpressibleByArgument`. Invalid
values become hard errors listing allowed values. Note in `--level` help that it only
affects the fallback text path.

---

## Phase 2 — Mixed-source text: positioned runs + SourcePolicy

Replaces `HybridReconciler` (`LayoutResolver.swift:301-341`), which is broken today:
it splits `PDFPage.string` on `"\n\n"` (PDFKit almost never emits blank lines → one
giant chunk), and if Vision found ≤ 3 paragraphs the `abs(diff) <= 2` guard passes
and paragraph 1 becomes the entire page text. Zip-by-index also swaps text between
regions because content-stream order ≠ reading order.

### 2.1 Positioned text runs (PDF inspection backbone)

Extend `PDFStructureExtractor` to emit `[PositionedTextRun]` per page:
enumerate `attributedString` font runs; for each, get its rect via
`page.selection(for: NSRange)` → `bounds(for: .mediaBox)`; store
`(text, rectPoints, fontSize, fontName, isBold, isItalic)`. All Sendable, computed up
front while the `PDFPage` is in hand (PDFKit types are not Sendable — nothing
downstream may hold a page reference). Split runs that span multiple visual lines
(selection bounds per line via `selection.selectionsByLine()`).

### 2.2 Page signals + `SourcePolicy.swift`

Implement the page-class signals table and region rules from the design section as
pure functions:

```swift
enum SourcePolicy {
    static func classify(page: PageSignals) -> PageClass
    static func chooseText(ocr: String, ocrConfidence: Float,
                           layerRuns: [PositionedTextRun],
                           pageClass: PageClass) -> TextChoice
    // TextChoice: .layer(String) | .ocr | .ocrEscalate
}
```

Exhaustive unit tests — one per rule row, plus the digit-dense tightening and the
`scannedWithOCRLayer` similarity gate. Similarity: bounded Levenshtein on
case/whitespace-normalized prefixes (implement in `TextSimilarity.swift`, unit-tested
separately; no dependency).

### 2.3 New reconciler

For each Vision paragraph/heading element on `digital`/`mixed` pages: convert region
to PDF points (`Geometry.toPDFPoints` — written but unused today), collect runs by
center-in-region, sort top→bottom/left→right, join, `TextCleaner.normalize`, run
through `SourcePolicy.chooseText`. `--text-layer` modes become real:
`off` = never consult layer; `hybrid` (default) = policy as specified;
`prefer` = policy but with the length/similarity acceptance thresholds relaxed
(0.4→0.6 length, 0.7→0.5 similarity) for non-digit-dense regions.

### 2.4 Text normalization

`TextCleaner.normalize`: Unicode NFC, ligature expansion (ﬁﬂﬀﬃﬄ), soft-hyphen
removal, collapse space runs. Applied to ALL text at render time regardless of
source, so both sources produce identical bytes for identical content. Unit test per
transformation.

### 2.5 Tests

- Unit: run collection (two paragraphs, tolerance edges, length-deviation rejection).
- E2E: `simpleArticle()` → output paragraphs byte-match the drawn strings
  (invariant (3) green — the "no OCR errors on digital PDFs" guarantee).
- E2E negative: `scannedArticle().png` → paragraphs via pure OCR at ≥ 90% char
  accuracy; policy classifies the page `scanned`.
- E2E: `scannedArticle().pdf` (image-only, no layer) classified `scanned`; then add
  an OCR-layer variant if cheap, else unit-test `scannedWithOCRLayer` at policy level.

---

## Phase 3 — Reading order: vertical banding

### 3.1 Band-then-column ordering
`LayoutResolver.order` (`LayoutResolver.swift:94-98`) sorts full-width elements
(`col = -1`) before ALL column content — footers and figures jump to the top.
Replace with banding: sort by `minY`; full-width elements (≥ 0.8 width) split the
page into horizontal bands; run column detection per band; sort (column, minY, minX)
within each band; emit bands top to bottom. Per-band detection also fixes whole-page
column detection being defeated by one full-width element bridging the gap.

### 3.2 Tests
Unit: (a) title/two-columns/footer ordering; (b) figure mid-page stays mid-page
(covers the post-figure re-`order()` at `VisionMD.swift:345`).
E2E: `twoColumnWithFooter()` → invariant (4) green. **Lock goldens now.**

---

## Phase 4 — Document-level consistency

New `DocumentRefiner` stage between per-page processing and assembly, operating on
`[PageResult]`.

### 4.1 Document-wide heading calibration
Per-page body-size ratios make the same 14pt style H2 on one page, H3 on the next.
Pool run sizes across pages; document body size = weighted median; cluster sizes
above body (quantize 0.5pt) into ≤ 3 levels → H1/H2/H3; reclassify. `isBold` breaks
ties at body size. No level skipping (promote to fill gaps). Keep the per-page
line-height heuristic for `scanned` pages.
**Outline cross-check:** when `PDFDocument.outlineRoot` exists, match outline entries
to headings by text similarity + page; outline depth overrides cluster level on
conflict (the outline is author ground truth). This also feeds Phase 6.
Tests: clusterer unit tests; e2e 3-page fixture with same 18pt header on pages with
different size mixes → same `##` everywhere; outline-conflict unit test.

### 4.2 Repeated header/footer removal
Fingerprint text elements (digit-stripped normalized text + rounded region center);
fingerprints on ≥ 60% of pages (min 3) in top 12% / bottom 10% of page are furniture
→ drop. Flag `--keep-page-furniture` to disable.
Tests: `multiPageWithHeaders()` → header absent from body; 2-page docs untouched.

### 4.3 Cross-page paragraph stitching
Last paragraph of page N lacks terminal punctuation AND first paragraph of page N+1
starts lowercase (or N ends with hyphen) → merge; de-hyphenate when the joined word
has no digits. Paragraph→paragraph only; runs before page-comment insertion.
Tests: hyphenated break joins; sentence-final break doesn't; table-final page doesn't.

### 4.4 Inline bold/italic
`PDFTextRun.isBold/isItalic` are captured and never used. In the reconciler, emit
`**…**` / `*…*` for runs differing from body style (runs ≥ 2 chars, whitespace outside
markers, coalesce adjacent same-style runs, never inside pipe cells). Unit test the
span builder; fixture with mid-paragraph bold phrase.

---

## Phase 5 — Tables (priority element)

Structure from Vision; cell text via SourcePolicy with the digit-dense rule. This
phase makes tables trustworthy.

### 5.1 Per-cell mixed-source text
For each Vision table cell on `digital`/`mixed` pages, map the cell's region
(`cell.content.boundingRegion` — extend `RawTable.RawCell` to carry it) to PDF
points and run `SourcePolicy.chooseText` with `digitDense` detection. Rejected +
low-confidence cells set `escalate` in the sidecar.
Tests: `simpleTable()` → invariant (5) green (cells byte-exact); a synthetic policy
test where layer and OCR disagree on a digit → OCR kept + escalated.

### 5.2 Header detection
Today row 0 is always the header. Improve: row 0 is a header iff (bold or larger
font in ≥ half its cells when digital) OR (row 0 is non-numeric while columns are
numeric below). When no header detected, emit an empty header row (GFM requires one)
and add `header_detected: false` to the sidecar table element.
Tests: headered fixture keeps header; headerless numeric grid gets empty header.

### 5.3 Cross-page table continuation
In `DocumentRefiner`: table at bottom of page N + table at top of page N+1 with the
same column count (and similar column x-bands) → merge rows; drop page-N+1's first
row when it repeats page-N's header (similarity ≥ 0.85 per cell). Emit one table at
page-N position.
Tests: `crossPageTable()` → single table, header once, all data rows present
(add invariant + golden).

### 5.4 Pipe-table polish
- `isNumeric` (`MarkdownRenderer.swift:221`) returns true for empty cells → all-empty
  columns right-align. Require ≥ 1 numeric non-empty cell.
- Column alignment from majority of cells, not all-or-nothing.
- Normalize cell text through `TextCleaner`.
- Single-column, many-row "tables" (Vision sometimes wraps TOCs/lists this way) with
  > 60% rows matching list/TOC patterns → demote to list (coordinates with Phase 6).

---

## Phase 6 — Table of contents (priority element)

TOCs are the worst case for naive pipelines: dot leaders OCR as garbage
(`.........` → `…`, random chars), right-aligned page numbers get detached or the
whole block is misdetected as a table. Dedicated handling:

### 6.1 Detection
A page region is a TOC candidate when either:
- a heading matching `^(contents|table of contents|index)$` (case-insensitive,
  localized list extendable) precedes it, or
- ≥ 4 consecutive lines match the TOC line pattern:
  `text … leader (dots/spaces ≥ 3) … number` with right-edge-aligned numbers
  (x-position clustering), or
- `PDFDocument.outlineRoot` exists and ≥ 60% of the region's lines match outline
  entry titles.

Implement as `TOCDetector` over per-line data (lines from Vision paragraphs split by
`lineCount` geometry on scanned pages; from positioned runs on digital pages —
digital preferred since dot leaders and numbers are exact there).

### 6.2 Extraction & rendering
Parse each TOC line into `(title, pageNumber, depth)` — depth from x-indent
clustering on the line's left edge; cross-validate/repair titles and ordering against
the PDF outline when present (outline wins on conflict). Render as a nested Markdown
list:

```markdown
## Contents

- [Introduction](#) — p. 3
  - [Background](#) — p. 4
- [Methods](#) — p. 7
```

With `--toc-links` (new flag, default on when outline exists): link entries to the
generated heading anchors (GitHub-style slugs of the matched headings from 4.1's
outline cross-check) instead of `#`. Suppress table detection inside confirmed TOC
regions (coordinate with 5.4's demotion rule). Sidecar: TOC emitted as
`type: "toc"` with entries array.

### 6.3 Tests
- Unit: TOC line parser (dots, spaced leaders, no leader + right-aligned number,
  nested indents, multi-line wrapped titles → join).
- E2E: `tableOfContents()` fixture → invariant (6) green: nested list, correct page
  numbers, no pipe/HTML table; entry depths match the fixture's outline.
- E2E: `simpleTable()` must NOT trigger TOC detection (guard against
  overtriggering — numeric last column ≠ page numbers unless leaders/outline agree).

---

## Phase 7 — Figures

### 7.1 Embedded-image extraction for digital PDFs
The band-scan (`Geometry.negativeSpace`) only finds full-width horizontal strips — a
figure beside a text column is invisible, and every crop spans the page width.
For digital pages, enumerate `/Resources/XObject` image entries (CGPDF) and export at
native resolution; recover placement rects from a content-stream operator scan
(`Do` operators + CTM). Time-box; if placement recovery is unreliable, keep raster
cropping but seed candidates from text-free connected regions instead of full-width
bands. Trim every crop to its content bounding box (extend `ImageStats` to return
non-white bounds) before the `isNearBlank` check.
Tests: `pageWithFigure()` → exactly one asset; bounds cover the drawn rect ±5%;
caption associated.

### 7.2 Content-hash filenames
`imageHash` samples 5 pixels. Use CryptoKit SHA-256 over the PNG data
(`CGImageDestinationCreateWithData` → hash → write); keep 8-char prefix.
Tests: same fixture twice → same name; altered fixture → different.

---

## Phase 8 — Robustness & performance

### 8.1 Lazy rasterization + bounded concurrency
`Rasterizer.load` renders every page up front (~33 MB/page at 300 DPI → 100-page PDF
≈ 3.3 GB) and the task group (`VisionMD.swift:139`) runs all pages at once.
Do all PDFKit inspection up front (cheap, produces the Sendable signals/runs from
Phase 2); move bitmap rendering into workers. PDFKit types are not Sendable — either
reopen the document per worker or serialize rendering through an actor feeding a
parallel Vision stage (prefer the actor; Vision dominates cost). Cap in-flight pages
at `min(4, ProcessInfo.processInfo.activeProcessorCount)` with a sliding-window task
group. Tests: 12-page fixture with cap 2 → output identical to serial; document a
manual `/usr/bin/time -l` RSS check.

### 8.2 Rasterization quality
Set `ctx.interpolationQuality = .high`. Measure OCR confidence on `scannedArticle()`
before/after; keep only if neutral-or-better.

---

## Phase 9 — Docs & release hygiene

- README: assets-dir naming (1.1); sidecar description (add `--sidecar full` to emit
  every element and make the "full structured output" claim true, or fix the claim);
  remove/implement "RecognizeTextRequest used automatically" (wire `recognizeTextOnly`
  behind `#unavailable(macOS 26)` if the platform floor is lowered);
  document the source-selection policy table (it's a selling point);
  update architecture diagram (SourcePolicy, DocumentRefiner, TOCDetector).
- Single version constant referenced by `CommandConfiguration`, front matter, and
  sidecar `tool` (three hardcoded `"0.1"`s today).

---

## How to run verification (Mac)

```bash
swift test                                   # full suite
swift test --filter "SourcePolicy"           # the routing criteria
swift test --filter "Table"                  # Phase 5
swift test --filter "TOC"                    # Phase 6
REGENERATE_GOLDEN=1 swift test --filter Golden   # intentional output changes

# Manual smoke test
swift run -c release visionmd ~/Documents/some-report.pdf --emit-json --verbose
```

Real-document acceptance checklist — run on: a digital report **with a TOC**, a
scanned doc, a previously-OCR'd scan, a two-column paper, an invoice, a financial
table-heavy PDF:

1. Every `![](...)` link opens.
2. Same visual heading style → same `#` level on every page; TOC entries match
   heading levels.
3. TOC renders as a nested list with correct page numbers — never as a table, never
   as dot-garbage.
4. Table cell values match the source **exactly** on digital PDFs (spot-check every
   numeric column); cross-page tables are merged with one header.
5. No page headers/footers in body; no swapped/duplicated paragraphs.
6. Reading order sane on the two-column paper; footer last.
7. `--tables off`, `--figures off`, `--text-layer off|prefer|hybrid` each visibly
   change output; `--verbose` logs which source (layer/OCR) each page class used.
8. 100+ page PDF completes, RSS < ~2 GB (`/usr/bin/time -l`).

## Suggested commit sequence

One commit per numbered task, message `Phase N.M: <imperative summary>`. Push after
each green phase so CI history brackets each phase. Phases 5 and 6 are the priority
deliverables after the Phase 1 bug fixes — if time-boxing, order is:
0 → 1 → 2 → 5 → 6 → 3 → 4 → 7 → 8 → 9.
