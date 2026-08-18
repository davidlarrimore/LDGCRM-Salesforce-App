# Technical Design diagrams

The five diagrams embedded in **`../Login.gov Partnerships CRM Technical Design - DRAFTED.docx`**,
with the source that produced them.

| Rendered | Source | Appears as |
| --- | --- | --- |
| `01-object-model.png` | `src-erd.html` | Figure 1, section 3.2 Object Model |
| `02-process-flow.png` | `src-flow.html` | Figure 2, section 3.3 High Level System Process Flow |
| `03-process-automation.png` | `src-automation.html` | Figure 3, section 4.1 Process Automation |
| `04-data-sharing-model.png` | `src-sharing.html` | Figure 4, section 4.3 Data Sharing Model |
| `05-migration-architecture.png` | `src-integration.html` | Figure 5, section 4.5 System Integration/Interface |

## Editing one

Each source is a standalone HTML file holding hand-placed inline SVG, plus the shared
`style.css`. Open one in a browser to see the change immediately. Coordinates are literal, so
moving a box means moving the connectors that reach it &mdash; that is deliberate, and it is why
the sources are kept rather than only the PNGs.

## Re-rendering

Headless Chrome, at a device scale factor of 2 so the PNG is ~400 DPI at the 6.5 inch width the
document places it at. Match `--window-size` to the SVG's own `width`/`height`.

```powershell
& "C:\Program Files\Google\Chrome\Application\chrome.exe" --headless --disable-gpu `
    --hide-scrollbars --force-device-scale-factor=2 --window-size=1560,900 `
    --user-data-dir="$env:TEMP\chrome-render" `
    --screenshot="01-object-model.png" "file:///$PWD/src-erd.html"
```

**`--user-data-dir` is not optional**, even though it looks like it should be. Without a writable
profile directory Chrome exits silently, writing no PNG and printing nothing &mdash; so the failure
looks exactly like a bad path or a malformed source. Point it anywhere disposable. (Confirmed on
Chrome 150; `--headless`, `--headless=old` and `--headless=new` all behave identically here.)

Sizes, which must match the SVG root element in each source:

| Source | `--window-size` |
| --- | --- |
| `src-erd.html` | `1560,900` |
| `src-flow.html` | `1560,790` |
| `src-automation.html` | `1560,975` |
| `src-sharing.html` | `1560,840` |
| `src-integration.html` | `1560,830` |

**Check the PNG's pixel dimensions after rendering.** A mismatched `--window-size` crops
silently: Chrome writes a smaller image rather than failing, and the missing strip is usually
the legend or the last row of a table, which is easy to miss in a thumbnail.

## Putting a re-rendered diagram back into the document

The `.docx` is an ordinary OOXML package: the five PNGs sit in `word/media/` under these same
filenames. Replacing one in place is enough, **provided the new PNG has the same aspect ratio**
&mdash; the document fixes each image at 6.5 inches wide and stores an explicit height in EMU, so
a differently-shaped PNG is stretched rather than re-fitted.

If the shape has to change, the stored height for that image has to change with it. In
`word/document.xml` each figure carries its size twice, as `<wp:extent cx cy>` and as
`<a:ext cx cy>`, and both must be set to the same value: `cy = 5943600 * pixelHeight /
pixelWidth`, rounded.
