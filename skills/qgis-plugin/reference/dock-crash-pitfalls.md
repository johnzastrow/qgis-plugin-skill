# QGIS dock / runtime crash pitfalls (segfaults, not exceptions)

Hard-won from real crashes. These are **C++ object-lifetime / signal-timing** bugs: a Python
`try/except` **cannot** catch them - QGIS just closes. When QGIS *crashes* (as opposed to showing a
traceback), look here first.

## The diagnostic method (when you cannot read the cause off the code)

1. **Crash-surviving trace.** A segfault loses buffered output, so log to a file with `flush()` and
   `fsync()` after **each** step; the last line before the crash names the culprit. Example helper:
   ```python
   def _dbg(self, msg):
       try:
           with open(os.path.expanduser("~/plugin_debug.log"), "a") as fh:
               fh.write(msg + "\n")
               fh.flush()
               os.fsync(fh.fileno())
       except Exception:
           pass
   ```
   Instrument the suspect loop granularly (per item, before and after each risky call), deploy,
   reproduce, read the log. Strip it once found.
2. **Pristine-backup bisection.** If unsure whether *your* change caused it, deploy a pristine backup
   and have the user run the exact repro. If pristine also crashes, it is a pre-existing bug (possibly
   a latent one your change merely un-hid). If pristine is clean, it is your change - bisect it.
3. **Reproduce it in a headless test** (see "Local testing" below) so the fix has a regression guard.

## Pitfall 1 - dangling symbols from renderer containers (use-after-free)

**The worst offender.** `cat.symbol()` / `rng.symbol()` / `rule.symbol()` return `QgsSymbol*` pointers
**owned by the temporary** `QgsRendererCategory` / `QgsRendererRange` / rule objects that
`renderer.categories()` / `.ranges()` / `rootRule().descendants()` return. A comprehension like:

```python
symbols = [cat.symbol() for cat in renderer.categories()]   # DANGLING once the temp list is GC'd
for s in symbols:
    s.symbolLayers()        # use-after-free -> SEGFAULT
```

stores symbol pointers whose owning container is garbage-collected right after the comprehension.
`singleSymbol` is safe (the symbol is owned by the long-lived renderer); categorized, graduated and
rule-based are not.

**Fix: clone to get Python-owned copies** while the container is still alive:

```python
symbols = []
for cat in renderer.categories():
    s = cat.symbol()
    if s is not None:
        symbols.append(s.clone())
```

General rule: **never hold a bare pointer returned from a temporary QGIS container across that
container's lifetime.** Call `.clone()`, or fully process it inline, before the container dies.

## Pitfall 2 - reading layers during `layersAdded`/`layersRemoved` (project-load teardown)

A project load fires a **storm** of `layersRemoved` (old) then `layersAdded` (new) while layers are
half-built or half-deleted. Rebuilding a layer list synchronously in those handlers touches layers in a
transitional state and crashes. **Debounce** so the refresh runs once, after the load settles:

```python
QgsProject.instance().layersAdded.connect(self._schedule_refresh)
QgsProject.instance().layersRemoved.connect(self._schedule_refresh)

def _schedule_refresh(self, *a):
    if getattr(self, "_pending", False):
        return
    self._pending = True
    QTimer.singleShot(250, self._do_refresh)   # coalesce; run when idle
```

## Pitfall 3 - `mapLayers()` vs `layerTreeRoot().layerOrder()`

`layerOrder()` gives nice panel order **but returns EMPTY for some projects - notably a project
stored in a GeoPackage**, producing a mysteriously blank layer list. Use `mapLayers().values()` for
reliability (accepting arbitrary order), and **skip `not layer.isValid()`**. Do *not* iterate
`mapLayers()` inside a teardown handler - combine this with Pitfall 2's debounce.

## Pitfall 4 - `QListWidget.clear()` with a live selection

`clear()` on a list that has **selected** items emits `itemSelectionChanged` **mid-mutation**; a slot
that then reads `selectedItems()` hits half-deleted items and crashes. Wrap the rebuild:

```python
blocked = self.layer_list.blockSignals(True)
try:
    self.layer_list.clear()
    # ... rebuild ...
finally:
    self.layer_list.blockSignals(blocked)
self._update_dependent_ui()     # call the slots once, on a consistent state
```

This one only bites when a selection exists - for example a Refresh button clicked after selecting
layers - so it can hide until a specific interaction.

## Pitfall 5 - `geometryType()` is an enum on QGIS 4 (PyQt6)

Returns `Qgis.GeometryType` (e.g. `<GeometryType.Line: 1>`), not an int. `geom_type == 0` silently
fails, so everything gets labelled generically. Normalise with `int(layer.geometryType())`.

## Pitfall 6 - `showEvent`-driven heavy work

Refreshing on every `showEvent` re-runs during dock undock/redock and during **plugin reload and
teardown**, on a half-destroyed widget, and crashes. Prefer explicit refresh (init, user action,
debounced signal). If you must hook it, guard with `hasattr(self, 'widget')` and keep it trivial.

## Pitfall 7 - a removed QGIS-4 attribute hidden behind `getattr(obj, 'x', default)`

Not a crash, which is what makes it worse. Some QGIS attributes moved onto sub-objects across 3 to 4.
`getattr(qgis_obj, 'oldAttr', default)` **silently returns `default`** when the attribute is gone, so
the plugin runs and quietly ignores the real setting. No exception, no crash, just wrong output.

When porting to QGIS 4, grep for `getattr(<qgis object>, '...', ...)` and prefer direct access (let it
raise) or an explicit `hasattr` branch per QGIS version, so a rename surfaces loudly instead of
defaulting.

## Local testing (catch these before the user does)

Run the dock against **real** layers and renderers under QGIS's own Python - the pure-Python suite
mocks `qgis` and cannot see any of the above.

```bash
export QT_QPA_PLATFORM=offscreen     # in-process bindings import without a display
# Point PYTHONPATH at your QGIS install's python dir, your distro's dist-packages,
# and the repo (plus its parent, so the plugin package itself is importable).
export PYTHONPATH=/usr/share/qgis/python:/usr/lib/python3/dist-packages:<repo-parent>:<repo>
python3 -m unittest test.test_dock_qgis -v
```

Find the right interpreter and paths for your system:
- **Linux**: `qgis --version`, then use the `python3.X` that QGIS was built against; the QGIS python
  dir is usually `/usr/share/qgis/python`.
  With a venv or pyenv active, `python3` is the wrong interpreter: run
  `PATH=/usr/bin:/bin QT_QPA_PLATFORM=offscreen /usr/bin/python3 -I ...` (`-I` also keeps user
  site-packages and the current directory off `sys.path`) and add `/usr/share/qgis/python` to
  `sys.path` in the test bootstrap or conftest.
- **Windows**: skip PYTHONPATH entirely and run `"C:\OSGeo4W\bin\python-qgis.bat" -m unittest ...`,
  which sets the full environment for you.
- **macOS**: use the Python bundled inside `QGIS.app`.

Guidance that matters:
- Import the dock **package-qualified** (`import myplugin.mydock`) so its relative `from .x` imports
  resolve; pass a minimal fake `iface`.
- Build fixtures for **every (geometry x renderer)** combination - especially a **categorized
  polygon** (Pitfall 1). Call the symbology inspection path and a full layer-list refresh; a crash
  kills the process, so simply returning *is* the assertion (exit 139 means it crashed, so the test failed).
- **Gate on an env var** (`<PLUGIN>_QGIS_TEST=1`), not on an `import qgis` check - the pytest conftest
  usually *mocks* `qgis`, so the import "succeeds" and the tests would run against MagicMocks.
- Ignore `QThreadStorage ... destroyed` warnings and **exit 139 at shutdown** (QGIS singletons do not
  tear down cleanly). Judge by the unittest `OK`/`FAILED` line.
- Prove a regression test has teeth: temporarily reintroduce the bug and confirm the test segfaults.

See `../scripts/deploy_local.sh` for the install-into-the-QGIS-profile click-test loop.
