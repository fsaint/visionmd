# visionmd Quality Evaluation Skill

## Purpose
Run a structured quality evaluation of visionmd output across all document types in `sample_pdfs/`. Report heading counts, false-positive rates, and flag regressions. Optionally open side-by-side previews.

## Trigger
`/quality-eval`, "evaluate quality", "check output quality", "run quality eval"

## Steps

### 1. Build (release)
```bash
swift build -c release --product visionmd
```

### 2. Re-process all sample PDFs
```bash
BIN=.build/release/visionmd
for pdf in sample_pdfs/*.pdf; do
  stem=$(basename "$pdf" .pdf)
  "$BIN" "$pdf" --output "sample_output/${stem}.md" --quiet 2>/dev/null
  echo "✓ $stem"
done
```

### 3. Collect stats per file
For each `.md` in `sample_output/`, report:
- Word count
- H1 / H2 / H3 heading counts
- Low-confidence warning count (`⚠️`)
- Figure reference count

Use this shell snippet:
```bash
OUT=sample_output
printf "%-50s  words  H1  H2  H3  ⚠️  figs\n" "File"
for f in "$OUT"/*.md; do
  name=$(basename "$f" .md | cut -c1-50)
  words=$(wc -w < "$f" | tr -d ' ')
  h1=$(grep -c "^# " "$f" 2>/dev/null || echo 0)
  h2=$(grep -c "^## " "$f" 2>/dev/null || echo 0)
  h3=$(grep -c "^### " "$f" 2>/dev/null || echo 0)
  low=$(grep -c "Low-confidence" "$f" 2>/dev/null || echo 0)
  figs=$(grep -c "^!\[" "$f" 2>/dev/null || echo 0)
  printf "%-50s  %5d  %3d %3d %3d %4d %4d\n" "$name" "$words" "$h1" "$h2" "$h3" "$low" "$figs"
done
```

### 4. Quality thresholds (flag if exceeded)

| Doc type | Max H1 | Max H2 | Max H3 | Notes |
|---|---|---|---|---|
| spec | 0 | 0 | 60 | Section codes only |
| observations | 0 | 2 | 20 | ACTION + section |
| rfi | 2 | 5 | 10 | Cover table + body |
| daily_report | 2 | 5 | 30 | Weather + sections |
| contract | 5 | 20 | 80 | Letterhead + items |
| bulletin | 5 | 5 | 20 | Cover + attachments |
| four_wla | 5 | 15 | 80 | Schedule docs — noisy |
| drawing_sheet | 2 | 2 | 5 | Mostly graphical |
| drawings | 10 | 10 | 20 | Title block + annotations |
| submittal | 15 | 15 | 50 | Cover + shop drawing |
| pay_application | 20 | 30 | 100 | Forms + invoices |

### 5. Known regressions to watch
- **G702 pay app crash**: should exit 0 on full 138-page run
- **four_wla heading inflation**: H3 > 80 is a regression signal
- **Observation doc**: must preserve `### ACTION` and `### CONSTRUCTION FIELD REPORT #N` headings
- **Spec sections**: H3 headings must start with section codes like `09 8453`, `1.01`

### 6. Side-by-side preview (optional)
```bash
# Build vmdpreview if not already done
swift build -c release --product vmdpreview

BIN_PREVIEW=.build/release/vmdpreview

# Open one doc type for visual inspection
"$BIN_PREVIEW" "sample_pdfs/observations__20250605_LWA-FR-46.pdf" \
               "sample_output/observations__20250605_LWA-FR-46.md"
```

Or use the interactive menu (see Step 7).

### 7. Interactive sample picker
To open any sample doc pair in the side-by-side viewer:
```bash
BIN_PREVIEW=.build/release/vmdpreview
select pdf in sample_pdfs/*.pdf; do
  stem=$(basename "$pdf" .pdf)
  "$BIN_PREVIEW" "$pdf" "sample_output/${stem}.md"
  break
done
```

Or pass the doc type prefix:
```bash
TYPE=spec  # change to: bulletin, contract, daily_report, drawing_sheet,
           #             drawings, four_wla, observations, pay_application,
           #             rfi, spec, submittal
pdf=$(ls sample_pdfs/${TYPE}__*.pdf | head -1)
stem=$(basename "$pdf" .pdf)
.build/release/vmdpreview "$pdf" "sample_output/${stem}.md"
```

## Reporting format

Summarize findings as:

```
## Quality Report — <date>

### Summary
- X/22 files processed
- N regressions detected / no regressions

### Per-type results
| type | files | status | notes |
| ... |

### Issues
1. <issue>: <file> — <details>

### Preserved
- <what's working correctly>
```
