// vmdpreview — side-by-side PDF + Markdown viewer
//
// Usage: vmdpreview <input.pdf> [input.md]
//
// Copies the PDF to a temp dir, generates a self-contained HTML comparison page,
// and opens it in the default browser.  If the .md file isn't provided,
// it's inferred by replacing the PDF extension.

import AppKit
import Foundation

// MARK: - Argument parsing

let cliArgs = CommandLine.arguments.dropFirst()

func usage() -> Never {
    fputs("""
    Usage: vmdpreview <input.pdf> [input.md]
           vmdpreview --samples [<doc-type>]
           vmdpreview --all
           vmdpreview --list

    Options:
      -h, --help              Show this help
      --samples [<type>]      Open a sample doc (bulletin, contract, daily_report,
                              drawing_sheet, drawings, four_wla, observations,
                              pay_application, rfi, spec, submittal)
      --all                   Generate previews for EVERY sample doc and open
                              a gallery index page linking to them
      --list                  List available sample docs

    If input.md is omitted, <input-stem>.md is tried automatically.
    Run visionmd on the PDF first to generate the Markdown.\n
    """, stderr)
    exit(1)
}

// MARK: - Sample-docs mode

/// Locate the sample_pdfs directory relative to this binary's package root.
func sampleDir() -> URL? {
    // Walk up from the binary until we find sample_pdfs/
    var dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    for _ in 0..<8 {
        let candidate = dir.appendingPathComponent("sample_pdfs")
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        dir = dir.deletingLastPathComponent()
    }
    return nil
}

func listSamples() {
    guard let dir = sampleDir() else {
        fputs("sample_pdfs/ not found (run from the package root or install the binary there).\n", stderr)
        exit(1)
    }
    let pdfs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
        .filter { $0.pathExtension.lowercased() == "pdf" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    print("Available sample docs (\(pdfs.count)):")
    for (i, p) in pdfs.enumerated() {
        print("  \(i + 1). \(p.deletingPathExtension().lastPathComponent)")
    }
}

func openSample(type: String?) {
    guard let dir = sampleDir() else {
        fputs("sample_pdfs/ not found.\n", stderr)
        exit(1)
    }
    let outDir = dir.deletingLastPathComponent().appendingPathComponent("sample_output")
    let allPDFs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
        .filter { $0.pathExtension.lowercased() == "pdf" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

    let filtered: [URL]
    if let t = type, !t.isEmpty {
        filtered = allPDFs.filter { $0.lastPathComponent.hasPrefix(t) }
    } else {
        filtered = allPDFs
    }

    guard !filtered.isEmpty else {
        fputs("No sample docs found for type '\(type ?? "")'.\n", stderr)
        fputs("Available types: \(allPDFs.map { $0.lastPathComponent.components(separatedBy: "__").first ?? "" }.reduce(into: Set<String>()) { $0.insert($1) }.sorted().joined(separator: ", "))\n", stderr)
        exit(1)
    }

    if filtered.count == 1 {
        let pdf = filtered[0]
        let md = outDir.appendingPathComponent(pdf.deletingPathExtension().lastPathComponent + ".md")
        openPair(pdfURL: pdf, mdURL: md)
        return
    }

    // Multiple matches — print a numbered menu
    print("Select a sample doc:")
    for (i, p) in filtered.enumerated() {
        print("  \(i + 1). \(p.deletingPathExtension().lastPathComponent)")
    }
    print("Enter number (1–\(filtered.count)): ", terminator: "")
    if let line = readLine(), let n = Int(line), n >= 1, n <= filtered.count {
        let pdf = filtered[n - 1]
        let md = outDir.appendingPathComponent(pdf.deletingPathExtension().lastPathComponent + ".md")
        openPair(pdfURL: pdf, mdURL: md)
    } else {
        fputs("Invalid selection.\n", stderr)
        exit(1)
    }
}

/// Generate a preview directory (doc.pdf + index.html) for one PDF/MD pair.
/// Returns the index.html URL, or nil when the PDF is missing.
@discardableResult
func generatePair(pdfURL: URL, mdURL: URL, into previewDir: URL) -> URL? {
    guard FileManager.default.fileExists(atPath: pdfURL.path) else {
        fputs("PDF not found: \(pdfURL.path)\n", stderr)
        return nil
    }
    var mdContent = ""
    if FileManager.default.fileExists(atPath: mdURL.path),
       let text = try? String(contentsOf: mdURL, encoding: .utf8), !text.isEmpty {
        mdContent = text
    } else {
        mdContent = "> **No Markdown file found.** Run `visionmd \"\(pdfURL.lastPathComponent)\"` first."
        fputs("Warning: \(mdURL.lastPathComponent) not found — showing placeholder.\n", stderr)
    }
    try? FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)
    let pdfDest = previewDir.appendingPathComponent("doc.pdf")
    try? FileManager.default.removeItem(at: pdfDest)
    try? FileManager.default.copyItem(at: pdfURL, to: pdfDest)
    let htmlDest = previewDir.appendingPathComponent("index.html")
    let html = buildHTML(title: pdfURL.deletingPathExtension().lastPathComponent, markdown: mdContent)
    try? html.write(to: htmlDest, atomically: true, encoding: .utf8)
    return htmlDest
}

func openPair(pdfURL: URL, mdURL: URL) {
    let previewDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vmdpreview-\(pdfURL.deletingPathExtension().lastPathComponent)")
    guard let htmlDest = generatePair(pdfURL: pdfURL, mdURL: mdURL, into: previewDir) else {
        exit(1)
    }
    NSWorkspace.shared.open(htmlDest)
    print("Preview: \(htmlDest.path)")
    exit(0)
}

// MARK: - Gallery mode (--all)

/// Generate previews for every sample doc plus an index page, open the index.
func openAll() {
    guard let dir = sampleDir() else {
        fputs("sample_pdfs/ not found.\n", stderr)
        exit(1)
    }
    let outDir = dir.deletingLastPathComponent().appendingPathComponent("sample_output")
    let allPDFs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
        .filter { $0.pathExtension.lowercased() == "pdf" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    guard !allPDFs.isEmpty else {
        fputs("No PDFs in \(dir.path).\n", stderr)
        exit(1)
    }

    let galleryDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vmdpreview-gallery")
    try? FileManager.default.createDirectory(at: galleryDir, withIntermediateDirectories: true)

    struct Entry {
        let stem: String
        let docType: String
        let relHref: String
        let words: Int
        let headings: Int
        let warnings: Int
        let hasMD: Bool
    }

    var entries: [Entry] = []
    for (i, pdf) in allPDFs.enumerated() {
        let stem = pdf.deletingPathExtension().lastPathComponent
        let md = outDir.appendingPathComponent(stem + ".md")
        // Directory-safe name: index avoids collisions from odd characters.
        let subdir = galleryDir.appendingPathComponent("doc-\(i)")
        guard generatePair(pdfURL: pdf, mdURL: md, into: subdir) != nil else { continue }

        var words = 0, headings = 0, warnings = 0, hasMD = false
        if let text = try? String(contentsOf: md, encoding: .utf8) {
            hasMD = true
            words = text.split(whereSeparator: \.isWhitespace).count
            for line in text.components(separatedBy: "\n") {
                if line.hasPrefix("#") { headings += 1 }
                if line.contains("Low-confidence") { warnings += 1 }
            }
        }
        entries.append(Entry(
            stem: stem,
            docType: stem.components(separatedBy: "__").first ?? "other",
            relHref: "doc-\(i)/index.html",
            words: words, headings: headings, warnings: warnings, hasMD: hasMD
        ))
        print("✓ \(stem)")
    }

    // Build the index page, grouped by doc type.
    var rows = ""
    let grouped = Dictionary(grouping: entries, by: \.docType).sorted { $0.key < $1.key }
    for (docType, docs) in grouped {
        rows += "<h2>\(escapeHTMLText(docType)) <span class=\"count\">\(docs.count)</span></h2>\n<ul>\n"
        for e in docs.sorted(by: { $0.stem < $1.stem }) {
            let title = e.stem.replacingOccurrences(of: "\(e.docType)__", with: "")
            let stats = e.hasMD
                ? "\(e.words.formatted()) words · \(e.headings) headings · \(e.warnings) ⚠️"
                : "no markdown"
            rows += """
              <li><a href="\(e.relHref)">\(escapeHTMLText(title))</a>
                  <span class="stats">\(stats)</span></li>\n
            """
        }
        rows += "</ul>\n"
    }

    let indexHTML = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="UTF-8">
    <title>visionmd — sample gallery</title>
    <style>
      body { font-family: -apple-system, BlinkMacSystemFont, sans-serif;
             max-width: 860px; margin: 2rem auto; padding: 0 1rem;
             color: #1f2328; line-height: 1.5; }
      h1 { font-size: 1.5rem; }
      h1 .sub { font-size: .9rem; font-weight: 400; color: #57606a; }
      h2 { font-size: 1.05rem; margin: 1.5em 0 .4em; text-transform: uppercase;
           letter-spacing: .04em; color: #57606a;
           border-bottom: 1px solid #d0d7de; padding-bottom: .25em; }
      h2 .count { font-weight: 400; color: #8b949e; font-size: .85em; }
      ul { list-style: none; margin: 0; padding: 0; }
      li { display: flex; justify-content: space-between; align-items: baseline;
           gap: 1rem; padding: .35em .5em; border-radius: 6px; }
      li:hover { background: #f6f8fa; }
      a { color: #0969da; text-decoration: none; font-size: .95rem;
          overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      a:hover { text-decoration: underline; }
      .stats { color: #8b949e; font-size: .8rem; white-space: nowrap; }
    </style>
    </head>
    <body>
    <h1>visionmd sample gallery <span class="sub">— \(entries.count) documents, PDF vs Markdown side by side</span></h1>
    \(rows)
    </body>
    </html>
    """

    let indexDest = galleryDir.appendingPathComponent("index.html")
    try? indexHTML.write(to: indexDest, atomically: true, encoding: .utf8)
    NSWorkspace.shared.open(indexDest)
    print("Gallery: \(indexDest.path)")
    exit(0)
}

func escapeHTMLText(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
}

// MARK: - Dispatch

if cliArgs.contains("--list") {
    listSamples()
    exit(0)
}

if cliArgs.contains("--all") {
    openAll()
    // openAll exits internally
}

if cliArgs.contains("--samples") {
    let idx = cliArgs.firstIndex(of: "--samples")!
    let next = cliArgs.index(after: idx)
    let docType: String? = next < cliArgs.endIndex && !cliArgs[next].hasPrefix("-") ? String(cliArgs[next]) : nil
    openSample(type: docType)
    // openSample calls exit(0) internally
}

if cliArgs.contains("-h") || cliArgs.contains("--help") || cliArgs.isEmpty { usage() }

let pdfPath = cliArgs.first!
let pdfURL  = URL(fileURLWithPath: pdfPath).standardizedFileURL

guard FileManager.default.fileExists(atPath: pdfURL.path) else {
    fputs("Error: file not found: \(pdfURL.path)\n", stderr)
    exit(1)
}

let mdURL: URL = {
    if let explicit = cliArgs.dropFirst().first {
        return URL(fileURLWithPath: explicit).standardizedFileURL
    }
    return pdfURL.deletingPathExtension().appendingPathExtension("md")
}()

// MARK: - Load markdown

var markdownContent: String
if FileManager.default.fileExists(atPath: mdURL.path),
   let text = try? String(contentsOf: mdURL, encoding: .utf8), !text.isEmpty {
    markdownContent = text
} else {
    let hint = mdURL.lastPathComponent
    markdownContent = """
    > **No Markdown file found** (`\(hint)`).
    >
    > Run `visionmd "\(pdfURL.lastPathComponent)"` to generate it, then re-run `vmdpreview`.
    """
    fputs("Warning: \(mdURL.path) not found — showing placeholder.\n", stderr)
}

// MARK: - Temp directory + PDF copy

let previewDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("vmdpreview-\(pdfURL.deletingPathExtension().lastPathComponent)")

try FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)

let pdfDest = previewDir.appendingPathComponent("doc.pdf")
try? FileManager.default.removeItem(at: pdfDest)
try FileManager.default.copyItem(at: pdfURL, to: pdfDest)

// MARK: - HTML generation

let htmlDest = previewDir.appendingPathComponent("index.html")
let html = buildHTML(
    title: pdfURL.deletingPathExtension().lastPathComponent,
    markdown: markdownContent
)
try html.write(to: htmlDest, atomically: true, encoding: .utf8)

// MARK: - Open

NSWorkspace.shared.open(htmlDest)
print("Preview: \(htmlDest.path)")

// MARK: - HTML builder

func buildHTML(title: String, markdown: String) -> String {
    // Base64-encode markdown to sidestep all escaping in JS template literals.
    let mdBase64 = Data(markdown.utf8).base64EncodedString()
    let escapedTitle = title
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")

    return """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>visionmd — \(escapedTitle)</title>
    <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    :root {
      --toolbar-h: 44px;
      --divider-w: 5px;
      --pdf-bg: #404040;
      --md-bg: #ffffff;
      --md-fg: #1f2328;
      --md-border: #d0d7de;
      --md-code-bg: #f6f8fa;
      --toolbar-bg: #1c1c1e;
      --toolbar-fg: #e5e5ea;
      --accent: #2f81f7;
    }

    html, body { height: 100%; overflow: hidden; }

    body {
      display: flex;
      flex-direction: column;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
      background: var(--toolbar-bg);
    }

    /* ── Toolbar ─────────────────────────────────── */
    .toolbar {
      height: var(--toolbar-h);
      background: var(--toolbar-bg);
      color: var(--toolbar-fg);
      display: flex;
      align-items: center;
      padding: 0 16px;
      gap: 12px;
      border-bottom: 1px solid #38383a;
      flex-shrink: 0;
      user-select: none;
    }
    .toolbar .logo {
      font-size: 13px;
      font-weight: 600;
      letter-spacing: .04em;
      color: var(--accent);
      white-space: nowrap;
    }
    .toolbar .sep { color: #636366; }
    .toolbar .filename {
      font-size: 13px;
      color: var(--toolbar-fg);
      opacity: .8;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .toolbar .spacer { flex: 1; }
    .toolbar .badge {
      font-size: 11px;
      background: #2c2c2e;
      border: 1px solid #48484a;
      border-radius: 4px;
      padding: 2px 8px;
      color: #aeaeb2;
      white-space: nowrap;
    }
    .toolbar button {
      font-size: 12px;
      background: #2c2c2e;
      border: 1px solid #48484a;
      border-radius: 5px;
      color: var(--toolbar-fg);
      padding: 4px 10px;
      cursor: pointer;
    }
    .toolbar button:hover { background: #3a3a3c; }

    /* ── Panels ──────────────────────────────────── */
    .panels {
      display: flex;
      flex: 1;
      overflow: hidden;
    }

    .panel {
      height: 100%;
      overflow: hidden;
      position: relative;
    }

    .panel-left {
      width: 50%;
      background: var(--pdf-bg);
      display: flex;
      flex-direction: column;
    }

    .panel-label {
      font-size: 11px;
      font-weight: 600;
      letter-spacing: .08em;
      text-transform: uppercase;
      padding: 6px 12px;
      background: rgba(0,0,0,.3);
      color: rgba(255,255,255,.4);
    }

    embed#pdf-embed {
      flex: 1;
      width: 100%;
      border: none;
      display: block;
    }

    .panel-right {
      width: 50%;
      background: var(--md-bg);
      display: flex;
      flex-direction: column;
    }

    .panel-right .panel-label {
      background: #f6f8fa;
      color: #57606a;
      border-bottom: 1px solid var(--md-border);
    }

    /* ── Divider ─────────────────────────────────── */
    .divider {
      width: var(--divider-w);
      background: #2c2c2e;
      cursor: col-resize;
      flex-shrink: 0;
      transition: background .15s;
    }
    .divider:hover, .divider.dragging { background: var(--accent); }

    /* ── Markdown output ─────────────────────────── */
    #md-output {
      flex: 1;
      overflow-y: auto;
      padding: 2rem 2.5rem;
      color: var(--md-fg);
      font-size: 15px;
      line-height: 1.65;
    }

    #md-output h1,
    #md-output h2,
    #md-output h3,
    #md-output h4 {
      margin: 1.4em 0 .4em;
      font-weight: 600;
      line-height: 1.25;
    }
    #md-output h1 { font-size: 1.75em; border-bottom: 1px solid var(--md-border); padding-bottom: .3em; }
    #md-output h2 { font-size: 1.35em; border-bottom: 1px solid var(--md-border); padding-bottom: .3em; }
    #md-output h3 { font-size: 1.1em; }
    #md-output h4 { font-size: 1em; }

    #md-output p  { margin: .75em 0; }
    #md-output ul,
    #md-output ol { margin: .5em 0 .5em 1.5em; }
    #md-output li { margin: .2em 0; }

    #md-output hr {
      border: none;
      border-top: 2px solid #e5e7eb;
      margin: 1.5em 0;
    }

    #md-output blockquote {
      border-left: 3px solid var(--accent);
      background: #f0f6ff;
      margin: .75em 0;
      padding: .5em 1em;
      color: #57606a;
      border-radius: 0 4px 4px 0;
    }

    #md-output code {
      font-family: 'SF Mono', 'Fira Code', Menlo, Consolas, monospace;
      font-size: .875em;
      background: var(--md-code-bg);
      border: 1px solid #e4e6e8;
      border-radius: 4px;
      padding: .1em .4em;
    }
    #md-output pre {
      background: #0d1117;
      border-radius: 6px;
      padding: 1em 1.25em;
      overflow-x: auto;
      margin: .75em 0;
    }
    #md-output pre code {
      background: transparent;
      border: none;
      padding: 0;
      color: #e6edf3;
      font-size: .85em;
    }

    #md-output table {
      border-collapse: collapse;
      width: 100%;
      margin: .75em 0;
      font-size: .9em;
    }
    #md-output th {
      background: #f6f8fa;
      font-weight: 600;
    }
    #md-output th, #md-output td {
      border: 1px solid var(--md-border);
      padding: .4em .75em;
      text-align: left;
    }
    #md-output tr:nth-child(even) td { background: #fafbfc; }

    #md-output img {
      max-width: 100%;
      border-radius: 4px;
      border: 1px solid var(--md-border);
    }

    #md-output a { color: var(--accent); text-decoration: none; }
    #md-output a:hover { text-decoration: underline; }

    /* ── Page marker comments → visible rule ─────── */
    .page-break {
      display: flex;
      align-items: center;
      gap: 8px;
      color: #8b949e;
      font-size: 11px;
      font-weight: 500;
      letter-spacing: .06em;
      margin: 1em 0;
    }
    .page-break::before, .page-break::after {
      content: '';
      flex: 1;
      border-top: 1px dashed #d0d7de;
    }
    </style>
    </head>
    <body>

    <div class="toolbar">
      <span class="logo">visionmd</span>
      <span class="sep">›</span>
      <span class="filename">\(escapedTitle).pdf</span>
      <span class="spacer"></span>
      <span class="badge" id="word-count">…</span>
      <button onclick="toggleRaw()" id="raw-btn">Raw MD</button>
    </div>

    <div class="panels" id="panels">

      <div class="panel panel-left" id="left-panel">
        <div class="panel-label">PDF Source</div>
        <embed id="pdf-embed" src="doc.pdf" type="application/pdf">
      </div>

      <div class="divider" id="divider"></div>

      <div class="panel panel-right" id="right-panel">
        <div class="panel-label">Markdown Output</div>
        <article id="md-output"></article>
      </div>

    </div>

    <script>
    // ── Decode markdown ──────────────────────────────────────────────────────
    const mdBase64 = "\(mdBase64)";
    const rawMD = new TextDecoder().decode(
      Uint8Array.from(atob(mdBase64), c => c.charCodeAt(0))
    );

    // ── Render ───────────────────────────────────────────────────────────────
    function renderMarkdown(text) {
      // Inline marked.js is fetched from CDN; fallback to preformatted raw.
      const out = document.getElementById('md-output');
      if (typeof marked !== 'undefined') {
        marked.setOptions({ breaks: false, gfm: true });
        out.innerHTML = marked.parse(text);
        // Inject visual page-break markers for <!-- page N --> comments.
        out.innerHTML = out.innerHTML.replace(
          /&lt;!-- page (\\d+) --&gt;/g,
          '<div class="page-break">PAGE $1</div>'
        );
      } else {
        out.innerHTML = '<pre>' + text.replace(/</g,'&lt;') + '</pre>';
      }
      // Word count
      const words = text.trim().split(/\\s+/).length;
      document.getElementById('word-count').textContent =
        words.toLocaleString() + ' words';
    }

    let showRaw = false;
    function toggleRaw() {
      showRaw = !showRaw;
      document.getElementById('raw-btn').textContent = showRaw ? 'Rendered' : 'Raw MD';
      if (showRaw) {
        document.getElementById('md-output').innerHTML =
          '<pre style="font-family:monospace;font-size:13px;white-space:pre-wrap;padding:1.5rem;color:#1f2328">'
          + rawMD.replace(/</g,'&lt;') + '</pre>';
      } else {
        renderMarkdown(rawMD);
      }
    }

    // ── Draggable divider ─────────────────────────────────────────────────────
    const divider  = document.getElementById('divider');
    const panels   = document.getElementById('panels');
    const leftPanel  = document.getElementById('left-panel');
    const rightPanel = document.getElementById('right-panel');

    let dragging = false, startX = 0, startLeftW = 0;

    divider.addEventListener('mousedown', e => {
      dragging = true;
      startX = e.clientX;
      startLeftW = leftPanel.getBoundingClientRect().width;
      divider.classList.add('dragging');
      document.body.style.cursor = 'col-resize';
      document.body.style.userSelect = 'none';
    });
    document.addEventListener('mousemove', e => {
      if (!dragging) return;
      const totalW = panels.getBoundingClientRect().width - 5;
      const newLeft = Math.max(200, Math.min(totalW - 200, startLeftW + (e.clientX - startX)));
      const pct = (newLeft / totalW * 100).toFixed(2);
      leftPanel.style.width  = pct + '%';
      rightPanel.style.width = (100 - parseFloat(pct)) + '%';
    });
    document.addEventListener('mouseup', () => {
      if (!dragging) return;
      dragging = false;
      divider.classList.remove('dragging');
      document.body.style.cursor = '';
      document.body.style.userSelect = '';
    });
    </script>

    <!-- marked.js from CDN — renders after load -->
    <script src="https://cdn.jsdelivr.net/npm/marked@9/marked.min.js"
            onload="renderMarkdown(rawMD)"
            onerror="renderMarkdown(rawMD)">
    </script>

    </body>
    </html>
    """
}
