# PyQGIS 4 API notes (verified on QGIS 4.2.3, Qt 6.10, PyQt6, Python 3.14)

Things that cost time while building a plugin that reads a whole project (layers, styles,
layouts, project XML) headless. Each entry: what happens, then what to do. The crash entries
matter most: a segfault cannot be caught (SKILL.md golden rule 1), so the only defence is to
recognise the case beforehand and not call into it.

---

## Crashers (avoid; `try/except` will not help)

| Call | What happens | Do instead |
|---|---|---|
| Rendering a layout (`QgsLayoutExporter` image/PDF export) that holds a **chart item** (`QgsLayoutItemChart`) whose source layer is missing or not loaded | Segfault in `QgsLayoutItemChart::prepareGatherer` (null source layer) | Before exporting, walk `layout.items()`; if a visible chart's `sourceLayer()` is `None` or `not isValid()`, skip the export and report why. Guard with `try: from qgis.core import QgsLayoutItemChart` for older builds |
| A layer created in a fixture or script and only put in the layer tree | Python garbage-collects the layer; later access crashes or the tree node is empty | `project.addMapLayer(layer, False)` first (the project then owns it), then `group.addLayer(layer)` |

The general shape: anything the renderer dereferences that is *optional* in the data model
(source layers, linked maps, atlas coverage layers) is a crash candidate when the project was
opened without loading layers (below). Check it in Python before rendering.

---

## Reading a project without touching the data

```python
from qgis.core import Qgis, QgsProject
project = QgsProject()
project.read(path, Qgis.ProjectReadFlag.DontResolveLayers)
```

- Layers come back **invalid** but with their XML state (style, fields from the XML, source
  string). Nothing is opened: no database login, no web request. This is the safe default for a
  tool that inspects untrusted projects.
- To load one layer's data afterwards, keeping the stored style:
  `layer.setDataSource(layer.source(), layer.name(), layer.providerType(), QgsDataProvider.ProviderOptions())`.
  Decide per provider whether that is allowed (do not contact web services or databases unless
  the user opted in).
- Anything that renders (thumbnails, layout exports) sees invalid layers as empty, and some item
  types crash on them (see the chart item above).

---

## Enum and flag changes (PyQt6)

- **Flag inversion returns an int.** `~QgsMapLayer.StyleCategory.CustomProperties` is a plain
  `int` in PyQt6, and `AllStyleCategories & ~x` no longer type-checks for APIs that want
  `StyleCategories`. Build the set positively: iterate `QgsMapLayer.StyleCategory`, skip the
  members you do not want, and OR the rest with `|`.
- `enum.name` works on scoped enums; keep a small helper that returns `value.name` when present
  and `str(value)` otherwise, and use it everywhere you serialise an enum.

## Renamed, removed or changed calls

Check any entry against your QGIS with a one-line `hasattr` before relying on it; QGIS keeps
deprecated calls for a while.

| QGIS 3 habit | QGIS 4 | Notes |
|---|---|---|
| `QgsApplication.rasterRendererRegistry()` | not exposed to Python | Keep your own `{type(): display name}` table for the built-in raster renderers |
| `layer.legendSymbologyItems()` | deprecated | `layer.renderer().legendSymbologyItems()` (vector) |
| `layer.importNamedStyle(doc)` | `layer.importNamedStyle(doc, categories)` | The two-argument form; it returns `(ok, error)` |
| `QgsLayoutItemLegend.autoUpdateModel()` | `syncMode()` (the old call still exists in 4.2 but is superseded) | Returns an enum; "Manual" means the legend is customised. Guard with `hasattr` if you support older 4.x |
| `QgsRelation()` then `setReferencingLayer(...)` | `QgsRelation(QgsRelationContext(project))` | Without the context the relation stays invalid and is silently dropped by `relationManager().addRelation()` |
| `QDomDocument.setContent(data)` returning `bool` | returns a **tuple** `(ok, message, line, column)` | `ok = r[0] if isinstance(r, tuple) else bool(r)`; a tuple is always truthy, so `if doc.setContent(...)` is a silent bug |

## Layout map items

- **Size first, then extent.** `item.attemptResize(QgsLayoutSize(...))` and only then
  `item.zoomToExtent(extent)`. Setting the extent on a zero-size item gives a map that draws
  nothing, with no warning. A null extent (`extent.isEmpty()`) also draws nothing: check and
  report it.

---

## Headless rendering

- Run with `QT_QPA_PLATFORM=offscreen` and a `QgsApplication([], False)` (no GUI). Image and PDF
  export from `QgsLayoutExporter`, `QgsMapRendererParallelJob` and `QPainter` on a `QImage` all
  work offscreen.
- **QtWebEngine is not part of QGIS builds**, so HTML-to-PDF via a browser engine is not
  available. For a PDF report use `QTextDocument` + `QPdfWriter`: feed simple HTML (tables need
  `border`/`cellpadding` attributes; most table CSS is ignored), register images in memory with
  `doc.addResource(QTextDocument.ResourceType.ImageResource.value, QUrl(name), qimage)` so
  nothing is loaded from disk, and draw page by page yourself if you want headers and footers
  (`doc.setPageSize`, then `drawContents` with a translated painter per page). An image taller
  than a page cannot split: scale it to the text area first.
- Cap the pixel size of anything you render from project settings (a layout page at 600 dpi can
  be hundreds of megapixels). Compute `width * height` before allocating and refuse or downscale.

---

## Parsing project XML safely

- `.qgs` is XML; `.qgz` is a zip holding one `.qgs`. Read the member **in memory** with a size
  cap (check `ZipInfo.file_size` and read at most cap + 1 bytes); never `extractall`.
- Parse with **`QDomDocument`** (already in QGIS, bounded entity expansion, no external entity
  loading) instead of `xml.etree`/`minidom`, which Bandit flags (B314/B318) and which need
  `defusedxml` to be safe. `QDomDocument` avoids the extra dependency, which a plugin cannot
  easily ship.
- **QGIS writes a DOCTYPE**: `<!DOCTYPE qgis PUBLIC 'http://mrcc.com/qgis.dtd' 'SYSTEM'>`. A filter
  that refuses every DOCTYPE (a common XXE defence) rejects every real project. Allow exactly that
  form (no internal subset, so no entities) and refuse any other DOCTYPE or `<!ENTITY`.
- **Project settings are `<properties name="X">`, not `<X>`.** In QGIS 4 the project property tree
  is written as nested `properties` elements named by attribute (`<properties name="Macros">`,
  `<properties name="Variables">`). Code that looks for a `<Macros>` tag finds nothing - which,
  for a macro filter, means it silently lets macros through. Match on the `name` attribute (and
  on the tag, for old projects).
- **Variables are two parallel lists.** Project, layer and layout variables are stored as
  `variableNames` and `variableValues` lists (`<value>` elements or `<Option value=...>`), so a
  value never sits next to its name. A redactor that hides values by key name misses a
  `service_token` variable; pair the lists by index.
- **Attribute values can hold whole XML documents** (a label's `lineSymbol`, a `text_format`), as
  escaped text. Scanning them as plain text finds false secrets (`pass="0"` in a symbol layer);
  parse and process them as XML, and leave them untouched when nothing changed.
- To redact secrets inside XML (style files, project XML), work on the parsed DOM (attribute
  values and text nodes), not with regexes over the serialised text: text-level redaction mangles
  attributes whose *name* happens to match a secret word (`pass="0"` in a symbol layer).
