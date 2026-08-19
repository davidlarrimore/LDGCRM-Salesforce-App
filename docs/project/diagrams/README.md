# Documentation diagrams

Every diagram that appears in a **`docs/project/` document** lives here, together with the source
that produced it. Nothing else in the repository holds an image.

## Naming

```
<document>-<NN>-<subject>.png     the render, embedded in the document
<document>-<NN>-<subject>.html    the source that produced it
```

**The leading `<document>` says which document the diagram belongs to**, so a file can be traced
back to its home without opening anything. `<NN>` is the figure order *within that document*, not a
global counter — a second document starts again at `01`. The `.png` and `.html` of one diagram share
a stem, so they sort next to each other and neither can be matched to the wrong partner.

Document prefixes in use:

| Prefix | Document |
| --- | --- |
| `technical-design-` | `../Login.gov Partnerships CRM Technical Design - DRAFTED.docx` |

## What is here

All five belong to the Technical Design.

| File | Source | Appears as |
| --- | --- | --- |
| `technical-design-01-object-model.png` | `technical-design-01-object-model.html` | Figure 1, section 3.2 Object Model |
| `technical-design-02-process-flow.png` | `technical-design-02-process-flow.html` | Figure 2, section 3.3 High Level System Process Flow |
| `technical-design-03-process-automation.png` | `technical-design-03-process-automation.html` | Figure 3, section 4.1 Process Automation |
| `technical-design-04-data-sharing-model.png` | `technical-design-04-data-sharing-model.html` | Figure 4, section 4.3 Data Sharing Model |
| `technical-design-05-migration-architecture.png` | `technical-design-05-migration-architecture.html` | Figure 5, section 4.5 System Integration/Interface |

`style.css` is shared by all five sources.

### What the other documents hold, so nobody re-checks

- **Technical Deployment Plan** — no diagrams. Its one image is the GSA logo.
- **Release Plan** — no images at all.
- **The operator runbooks** (`scripts/docs/`, `scripts/README.md`) carry an inline ASCII
  PULL → TRANSFORM → LOAD diagram. **It stays inline and is deliberately not collected here.**
  `scripts/` ships to the Operations team as a standalone bundle and may not reference a path above
  its own root, so a runbook pointing at `docs/project/diagrams/` would resolve to nothing for the
  people it is written for.

## The filenames inside the `.docx` are the OLD ones, on purpose

The document's `word/media/` entries are still `01-object-model.png` … `05-migration-architecture.png`,
without the prefix. The prefix is a *repository* convention; inside the package the names only have
to be unique, and renaming them would mean editing `word/_rels/document.xml.rels` for no gain. Strip
`technical-design-` from a filename here to get its name in the package.

## Editing one

Each source is a standalone HTML file holding hand-placed inline SVG, plus the shared `style.css`.
Open one in a browser to see the change immediately. Coordinates are literal, so moving a box means
moving the connectors that reach it — that is deliberate, and it is why the sources are kept rather
than only the PNGs.

## Re-rendering

Headless Chrome at a **device scale factor of 3**, so the PNG is roughly 720 DPI at the 6.5 inch
width the document places it at. Match `--window-size` to the SVG's own `width`/`height` — the scale
factor multiplies it, so the window size stays at the 1x figure.

```powershell
& "C:\Program Files\Google\Chrome\Application\chrome.exe" --headless --disable-gpu `
    --hide-scrollbars --force-device-scale-factor=3 --window-size=1560,900 `
    --user-data-dir="$env:TEMP\chrome-render" `
    --screenshot="technical-design-01-object-model.png" `
    "file:///$PWD/technical-design-01-object-model.html"
```

**`--user-data-dir` is not optional**, even though it looks like it should be. Without a writable
profile directory Chrome exits silently, writing no PNG and printing nothing — so the failure looks
exactly like a bad path or a malformed source. Point it anywhere disposable. (Confirmed on Chrome
150; `--headless`, `--headless=old` and `--headless=new` all behave identically here.)

Sizes, which must match the SVG root element in each source, and the pixels 3x produces:

| Source | `--window-size` | Rendered PNG |
| --- | --- | --- |
| `technical-design-01-object-model.html` | `1560,900` | 4680 x 2700 |
| `technical-design-02-process-flow.html` | `1560,790` | 4680 x 2370 |
| `technical-design-03-process-automation.html` | `1560,975` | 4680 x 2925 |
| `technical-design-04-data-sharing-model.html` | `1560,840` | 4680 x 2520 |
| `technical-design-05-migration-architecture.html` | `1560,830` | 4680 x 2490 |

**Check the PNG's pixel dimensions against that last column after rendering.** A mismatched
`--window-size` crops silently: Chrome writes a smaller image rather than failing, and the missing
strip is usually the legend or the last row of a table, which is easy to miss in a thumbnail.

## Putting a re-rendered diagram back into the document

The `.docx` is an ordinary OOXML package: the five PNGs sit in `word/media/` under their unprefixed
names. Replacing one in place is enough, **provided the new PNG has the same aspect ratio** — the
document fixes each image at 6.5 inches wide and stores an explicit height in EMU, so a
differently-shaped PNG is stretched rather than re-fitted.

Changing only the scale factor is always safe: it multiplies both dimensions, so the ratio is
unchanged and nothing in the document has to move.

If the shape *does* have to change, the stored height for that image has to change with it. In
`word/document.xml` each figure carries its size twice, as `<wp:extent cx cy>` and as `<a:ext cx cy>`,
and both must be set to the same value: `cy = 5943600 * pixelHeight / pixelWidth`, rounded.
