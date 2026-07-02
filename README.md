# visionmd

**PDF and image → clean Markdown, entirely on-device.**

`visionmd` is a Swift CLI that converts PDFs, scanned images, and image directories into structured Markdown using Apple Vision and PDFKit — no cloud, no API keys, no Python.

```bash
swift run visionmd report.pdf --output report.md
```

---

## Tools

This package ships two executables.

| Binary | Purpose |
|---|---|
| `visionmd` | Convert PDF / image → Markdown |
| `vmdpreview` | Side-by-side PDF + rendered Markdown viewer in the browser |

---

## Features

| Capability | How |
|---|---|
| **Text extraction** | Apple Vision `RecognizeDocumentsRequest` (macOS 26) with `RecognizeTextRequest` fallback |
| **Heading inference** | Font-size ratios from PDFKit for digital PDFs; line-height heuristic for scanned |
| **Table detection** | Native Vision table recognition with row/col spans, rendered as GFM pipe tables |
| **Figure extraction** | Negative-space cropping saves embedded images as PNG with caption association |
| **Multi-column layout** | Gap-based column detection + newspaper reading order |
| **List detection** | Ordered and unordered, with marker type preservation |
| **Barcode / QR** | Payload and symbology extracted inline |
| **Hybrid text layer** | PDFKit text layer used where available for sharper encoding; Vision for layout |
| **Sidecar JSON** | Full structured output with bounding boxes, confidence scores, page metadata |
| **Page range filtering** | `1-5,8,11-` syntax — process only what you need |
| **Large-PDF stability** | Per-page autoreleasepool + capped concurrency (8 tasks) prevents SIGSEGV on 100+ page JBIG2 PDFs |

---

## Requirements

- **macOS 26 (Tahoe)** or later
- Xcode 16+ / Swift 6+

> **macOS 15 mode:** Lower `platforms` in `Package.swift` to `.macOS(.v15)` to build without native document-recognition tables. `RecognizeTextRequest` is used automatically as a fallback.

---

## Installation

### Build from source

```bash
git clone https://github.com/fsaint/visionmd.git
cd visionmd
swift build -c release
# Binaries at: .build/release/visionmd  and  .build/release/vmdpreview
```

### Add to your PATH

```bash
sudo cp .build/release/visionmd   /usr/local/bin/
sudo cp .build/release/vmdpreview /usr/local/bin/
```

---

## visionmd

### Basic usage

```bash
# PDF → Markdown
visionmd report.pdf

# Image → Markdown
visionmd scan.png --output scan.md

# Directory of images → single Markdown
visionmd ./scans/ --output combined.md
```

### Options

```
ARGUMENTS:
  <input>                 Input .pdf, image (.png/.jpg/.heic/.tiff), or directory of images.

OPTIONS:
  -o, --output <output>         Output .md path. Default: <input-stem>.md
  --assets-dir <dir>            Directory for extracted figure PNGs
  --dpi <dpi>                   Rasterization DPI (default: 300)
  --lang <lang>                 BCP-47 language codes, e.g. en-US,es-ES (default: auto)
  --level <level>               fast | accurate (default: accurate)
  --pages <pages>               Page range: 1-5,8,11- (default: all)
  --text-layer <mode>           off | prefer | hybrid (default: hybrid)
  --tables <mode>               native | off (default: native)
  --figures <mode>              crop | off (default: crop)
  --min-figure-area <frac>      Min page-fraction for a figure crop (default: 0.02)
  --emit-json                   Write sidecar .ocr.json alongside the Markdown
  --json-output <path>          Custom sidecar JSON path (implies --emit-json)
  --min-confidence <float>      Flag elements below this threshold (default: 0.5)
  --front-matter                Prepend YAML front matter (source, pages, tool version)
  --page-rules                  Insert --- rules at page boundaries
  --hash-assets                 Stable 8-char content hash on figure filenames
  --no-headings                 Disable heading inference; emit all text as paragraphs
  --quiet                       Suppress informational output
  --verbose                     Verbose logging
```

### Examples

```bash
# Extract only pages 1–4 at high DPI, with sidecar JSON
visionmd drawing.pdf --pages 1-4 --dpi 400 --emit-json

# Scanned image, Spanish, fast mode
visionmd scan.jpg --lang es-ES --level fast

# Multi-language construction docs with figure crops in a separate folder
visionmd project.pdf --assets-dir ./figures --front-matter

# Quiet batch mode
for f in *.pdf; do
  visionmd "$f" --quiet --output "md/${f%.pdf}.md"
done
```

---

## vmdpreview

Side-by-side browser view: original PDF on the left, rendered Markdown on the right.

```bash
# Open a specific PDF + Markdown pair
vmdpreview report.pdf report.md

# Infer the .md path automatically (looks for report.md next to report.pdf)
vmdpreview report.pdf

# List all sample docs shipped with the repo
vmdpreview --list

# Open a sample doc by type — shows a numbered menu if multiple match
vmdpreview --samples observations
vmdpreview --samples spec
vmdpreview --samples rfi
```

**Viewer features:**
- Draggable divider — resize the split to any ratio
- **Raw MD** toggle — flip between rendered and source Markdown
- Word count in the toolbar
- Page-break markers — `<!-- page N -->` comments render as visible dashed rules
- Native macOS PDF viewer (full navigation and zoom controls)
- Requires internet to load `marked.js` from CDN (renders without it, but unstyled)

---

## Output format

### Headings

For **digital PDFs** with an embedded font layer, headings are inferred from font-size ratios relative to the body text. Text with Vision confidence below 0.55 is never promoted to a heading (prevents garbled OCR from producing false structure).

| Ratio vs body | Level |
|---|---|
| ≥ 1.6× | `# H1` |
| ≥ 1.3× | `## H2` |
| ≥ 1.1× | `### H3` |
| 1.0× + ALL CAPS | `### H3` |

For **scanned PDFs and images**, a line-height heuristic is used as fallback.

### Tables

Complex tables (merged cells, spanning headers) are emitted as raw HTML. Simple tables use GFM pipe syntax.

```markdown
| Item | Qty | Unit Price | Total |
|------|-----|-----------|-------|
| Concrete mix | 40 | $12.50 | $500.00 |
| Rebar #4 | 200 | $1.80 | $360.00 |
```

### Figures

Figures are saved as PNG and referenced inline:

```markdown
![Figure 1](figures/figure-001.png)
```

### Sidecar JSON

`--emit-json` writes a `.ocr.json` file with every element, its bounding box in normalized page coordinates, confidence score, and page index — useful for downstream processing.

```json
{
  "pages": [
    {
      "index": 0,
      "elements": [
        {
          "type": "heading",
          "level": 1,
          "text": "Project Summary",
          "region": { "x": 0.09, "y": 0.04, "width": 0.45, "height": 0.03 },
          "confidence": 0.98
        }
      ]
    }
  ]
}
```

---

## Architecture

```
Input (PDF / image / directory)
        │
        ▼
  ┌─────────────┐
  │  Rasterizer │  PDFKit → CGImage per page (autoreleasepool per page),
  │             │  extract text layer + font metadata (PDFPageFontInfo)
  └──────┬──────┘
         │  RasterizedPage (CGImage + fontInfo + pdfTextLayer)
         ▼
  ┌─────────────┐
  │  Recognizer │  Apple Vision RecognizeDocumentsRequest → paragraphs, tables, lists, barcodes
  │             │  (max 8 concurrent Vision tasks)
  └──────┬──────┘
         │  RawDocumentResult (Vision-space bounding boxes)
         ▼
  ┌────────────────┐
  │ LayoutResolver │  Coordinate flip, column detection, reading order,
  │                │  heading inference (font-size ratios + confidence gate)
  └──────┬─────────┘
         │  [DocElement] in reading order
         ▼
  ┌──────────────────┐
  │ HybridReconciler │  Replace Vision OCR text with PDFKit text where it matches
  └──────┬───────────┘
         │
         ▼
  ┌─────────────────┐   ┌──────────────────┐
  │MarkdownRenderer │   │ FigureExtractor  │  Negative-space crop → PNG
  └──────┬──────────┘   └──────┬───────────┘
         │                     │
         └──────────┬──────────┘
                    ▼
            .md + .ocr.json + figures/
```

---

## Why on-device?

- **Privacy** — documents never leave your machine
- **Speed** — no network round-trips; processes a 50-page PDF in seconds on Apple Silicon
- **Cost** — zero API fees regardless of volume
- **Accuracy** — Apple Vision is tuned for macOS and handles handwriting, forms, and multi-language docs natively

---

## License

MIT

---

## Contributing

Issues and PRs welcome. Run the test suite with:

```bash
swift test
```

36 tests, zero dependencies beyond Apple's frameworks and `swift-argument-parser`.
