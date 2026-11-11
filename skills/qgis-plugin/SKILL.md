---
name: qgis-plugin
description: >-
  Author, debug, package, and publish QGIS (3.x/4.x, PyQt5/PyQt6) Python plugins.
  Covers dock/UI patterns, the runtime crash pitfalls that segfault QGIS, Qt5-to-Qt6
  migration, the plugins.qgis.org security gates (Bandit/secrets/flake8), a
  self-verifying build, local-deploy testing, the release flow, and Windows/OSGeo4W
  specifics. Use for ANY QGIS plugin work - creating, upgrading, debugging a crash in,
  packaging, or publishing - including anything touching metadata.txt,
  __init__.py/classFactory, a QGIS dock widget or QgsTask, the plugin zip,
  plugins.qgis.org uploads, or QGIS's own Python (python-qgis.bat / OSGeo4W).
  Triggers: "QGIS plugin", "plugins.qgis.org", "metadata.txt", "qgisMinimumVersion",
  "PyQGIS dock", "classFactory", "QgsMapLayer", "Install from ZIP", "pb_tool".
---

# QGIS Plugin Development & Publishing

Battle-tested playbook distilled from shipping and upgrading real plugins. This file is the
operational index; deep detail lives in `reference/`, runnable tooling in `scripts/`, and
drop-in project files in `templates/`.

- **`reference/publishing-playbook.md`** - the full publishing playbook (metadata, packaging,
  gates, Qt6, testing under QGIS Python, release). Read it for anything below in depth.
- **`reference/dock-crash-pitfalls.md`** - the runtime/UI crash pitfalls (READ THIS before touching
  a dock widget or anything that reacts to QGIS layer signals).
- **`reference/qgis4-api-notes.md`** - PyQGIS 4 API changes and headless-rendering crashers found
  in practice (layout chart segfault, flag inversion, `QDomDocument.setContent` tuple, reading a
  project without opening its data, PDF without QtWebEngine). Read it before code that reads
  projects, styles or layouts, or renders anything headless.
- **`scripts/build_plugin.sh`** - self-verifying zip builder, driven by a manifest.
- **`scripts/build_plugin.py`** - same build with the Python stdlib only, for Windows/Git Bash
  (no `zip` binary) or when you would rather the manifest be parsed than executed.
- **`scripts/deploy_local.sh`** - build and install into the local QGIS profile for click-testing.
- **`templates/`** - `plugin_build.conf` (the build manifest), `Makefile`, `release.yml`,
  `setup.cfg`, `ruff.toml`. Copy into a plugin repo so every plugin releases identically.

**Setup for a plugin repo:** copy `scripts/` and `templates/plugin_build.conf` to the repo root,
edit the manifest, then `bash scripts/build_plugin.sh`. Nothing else needs per-plugin editing.

---

## Golden rules (the ones that actually bite)

1. **A crash (segfault) is not a Python exception.** `try/except` cannot catch a segfault. If QGIS
   *closes*, suspect C++ object lifetime: reading a layer/widget that is being torn down. See
   `reference/dock-crash-pitfalls.md`.
2. **Never read layers synchronously inside `layersAdded`/`layersRemoved` handlers.** A project load
   fires a storm of these while layers are half-built/half-deleted. **Debounce** (`QTimer.singleShot`)
   so the refresh runs *after* the load settles.
3. **`mapLayers()` vs `layerTreeRoot().layerOrder()`.** `layerOrder()` gives panel order but comes
   back **empty for some projects (e.g. a project stored in a GeoPackage)**, producing blank layer
   lists. Use `mapLayers().values()` for reliability, skip `not layer.isValid()`, and only at stable times.
4. **`blockSignals(True)` around any `QListWidget.clear()` + rebuild.** Clearing a list that has
   selected items emits `itemSelectionChanged` mid-mutation; slots then read half-deleted items and crash.
5. **Packaging drops subpackages silently.** `make`/`pb_tool` ship an incomplete zip, producing
   `ModuleNotFoundError` on install. Use `scripts/build_plugin.sh` with an explicit manifest and a
   self-verify step.
6. **QGIS 4 is PyQt6.** Old plugins break on unscoped enums and `.exec_()`. And without
   `qgisMaximumVersion=4.99`, QGIS 4 refuses to even load a `min=3.40` plugin.
7. **State assumptions; test in a real QGIS.** Static checks (compile/flake8) cannot catch enum breaks
   in un-exercised paths or C++ lifetime crashes. Deploy locally and click every path.
8. **Every control gets a helpful tooltip** (`setToolTip`) - buttons, radios, checkboxes, fields.
   Non-negotiable UX baseline. And **persist every user-facing option in all the places that store
   state**: the live `QgsSettings`, the Save/Load **config file** (schema + read + write), and the
   export settings dict. An option added to only some of them silently fails to round-trip.

---

## Runtime / dock stability (the crash class) - `reference/dock-crash-pitfalls.md`

The highest-value, hardest-won knowledge. Quick reference:

| Symptom | Cause | Fix |
|---|---|---|
| QGIS **crashes on project load** | Handler reads layers mid-teardown (esp. iterating `mapLayers()` while layers die) | Debounce `layersAdded/Removed`, refresh after load; skip `not isValid()` |
| QGIS **crashes when clicking Refresh / on selection** | `list.clear()` with a live selection fires `itemSelectionChanged` into a slot reading deleted items | `blockSignals(True)` around clear/rebuild, update dependent UI once after |
| **Blank layer list** for a gpkg-stored project | `layerTreeRoot().layerOrder()` returns empty | iterate `mapLayers().values()` |
| Crash **during plugin reload / dock teardown** | `showEvent`/handler runs on a half-destroyed widget | avoid `showEvent`-driven heavy work; guard with `hasattr`; prefer explicit refresh |
| Segfault iterating a **categorized/graduated** renderer | `cat.symbol()` returns a pointer owned by a temporary container that is then GC'd (use-after-free) | `.clone()` each symbol while the container is alive |
| Wrong `[Point]/[Line]/[Polygon]` labels on QGIS 4 | `geometryType()` returns an **enum** (PyQt6), not an int | `int(layer.geometryType())` or compare the enum |
| Segfault **exporting a layout** headless | A chart item (`QgsLayoutItemChart`) whose source layer is missing or not loaded | Check every visible chart's `sourceLayer()` first; skip the export if any is invalid (`reference/qgis4-api-notes.md`) |
| Layer created in a script/fixture **vanishes or crashes** | Layer added only to the layer tree, then garbage-collected | `project.addMapLayer(layer, False)` before `group.addLayer(layer)` |
| Labels **ignore QGIS placement** on QGIS 4 | A removed attribute read via `getattr(obj, 'x', default)` **silently returns the default** | Use the relocated API; audit every `getattr(<qgis obj>, 'x', default)` for a QGIS-4 rename that a getattr hides |

**Local-deploy test loop:**
```bash
bash scripts/deploy_local.sh                  # reads plugin_build.conf; -p PROFILE, -q QGIS3|QGIS4
# then: restart QGIS (or Plugin Reloader) - a full restart is the only sure reload
```
When a crash cannot be reproduced from code inspection, get the user to run the exact sequence with a
**pristine backup** deployed. If the pristine build also crashes, the bug is pre-existing, not the change.

---

## Testing - catch crashes before the user

The pure-Python unit suite usually **mocks `qgis`**, so it cannot see the C++/PyQt crashes above. Add a
**QGIS-integration tier** that runs the dock against *real* layers/renderers under QGIS's own Python
(headless, `QT_QPA_PLATFORM=offscreen`), with a fixture per **(geometry x renderer)** - especially a
**categorized polygon** (the classic dangling-symbol segfault). A crash kills the process (exit 139),
so "the call returned" *is* the assertion. **Gate on an env var** (`<PLUGIN>_QGIS_TEST=1`), not on
`import qgis` - the conftest mock makes the import succeed. Full recipe plus the QGIS-Python
environment in `reference/dock-crash-pitfalls.md` ("Local testing").

Linux one-liner that avoids the two usual traps (an active venv's python shadowing the system
one QGIS was built for, and user site-packages or the current directory leaking imports):
```bash
PATH=/usr/bin:/bin QT_QPA_PLATFORM=offscreen /usr/bin/python3 -I script.py
# inside script.py: sys.path.insert(0, "/usr/share/qgis/python") before importing qgis
```
**Generate fixtures with a script** (`tests/fixtures/make_fixtures.py`) that builds the projects,
GeoPackages and rasters under QGIS's Python, rather than committing hand-made `.qgz` files: the
fixtures stay reviewable, reproducible on a new QGIS, and free of absolute paths.

## Packaging & build - `reference/publishing-playbook.md` section 2

- Ship an **explicit file list** (every `.py`, every imported subpackage, `metadata.txt`, icon,
  `LICENSE`); strip `__pycache__`/`*.pyc`/`.git`. Top-level zip folder = the package name.
- **Self-verify** the built zip: assert required entries present; **reject** binaries, archives,
  `__pycache__`, compiled `resources.py`, `docs/`, **and `*.sh`** (see the gates section).
- **Icons**: load from a file path (`os.path.join(plugin_dir, 'icons', 'icon.svg')`), NOT compiled
  `resources.py`/`pyrcc5` - plugins.qgis.org bans generated resource files.
- Declare it once in `plugin_build.conf`; `build_plugin.sh` and `build_plugin.py` both read it, so
  the local build and CI cannot drift apart.
- **The `resources.py` ban is by file name, anywhere in the zip** - a hand-written module called
  `resources.py` (or `*resources.py`) is rejected too. Name modules for what they hold
  (`fonts_files.py`). A unit test that applies the same pattern to your source tree catches it
  before the build does.
- **Never pipe the build into `tail`/`head` and trust it.** The pipeline's status is the last
  command's, so a failed build "succeeds" and you ship or test the previous zip. Run it bare, or
  `set -o pipefail`, and check the exit code before using the zip.

## The plugins.qgis.org gates - `reference/publishing-playbook.md` section 4

Run locally with uv before uploading. **HIGH/critical Bandit findings and any secret are a hard block:**
```bash
uv run --no-project --with bandit bandit -r . -x ./test,./tests,./docs
uv run --no-project --with detect-secrets detect-secrets scan --all-files --exclude-files '^\.git/'   # exits 0 even on findings:
                                                    # read "results" (must be {}); `make leak-scan` checks it
uv run --no-project --with flake8 flake8 .          # authoritative style gate
```
- Iterate with `ruff check --fix` but **verify with `flake8`** (ruff lacks some E12x/W50x).
- Common fixes: B608 SQL to allowlist + `# nosec B608`; B112 try/except/continue to `# nosec B112`
  (use the *correct* code - B110 is pass, B112 is continue); XXE to `QDomDocument` (inside QGIS) or `defusedxml`; bare except to
  `except Exception:`.
- **`.ruff_cache/CACHEDIR.TAG`** is a false-positive secret: gitignore it and delete caches before scanning.
- **Intentional fake credentials in tests** (redaction tests need them): mark the line
  `# pragma: allowlist secret` so detect-secrets skips it. Never allowlist a real value.
- **Bandit B105 on lookup tables** (`{"password": ...}` dict keys read as hardcoded passwords):
  write the table value-first and invert it with a helper (`{kind: (names...)}` to `{name: kind}`)
  rather than scattering `# nosec`.
- **XML from a project or style file is untrusted.** Bandit flags `xml.etree`/`minidom` (B314/B318);
  inside QGIS use `QDomDocument` (bounded entity expansion, no external entities) instead of
  adding `defusedxml` as a dependency. Its `setContent` returns a tuple on QGIS 4 - a tuple is
  always truthy, so test `result[0]`.
- **Never name a make target `secrets:`** - detect-secrets reads it as a secret keyword and flags the
  recipe lines. The template's target is `leak-scan`. And `detect-secrets scan` **exits 0 even with
  findings**; a gate must check that the JSON `results` object is empty. Exclude `.git/`
  (`--exclude-files '^\.git/'`): in CI `.git/FETCH_HEAD` holds a quoted commit hash that is
  reported as a "Hex High Entropy String".
- **The security scanner flags shell-script installers.** A `*.sh` that downloads a binary and moves it
  into a system path is exactly the pattern that gets a plugin rejected. Do not ship installer shell
  scripts - put the guidance in the README and give an in-app link (`QDesktopServices.openUrl` to the
  official releases page). The build scripts reject `*.sh` in the zip by default.

## Qt5 to Qt6 (QGIS 4) - `reference/publishing-playbook.md` section 6

- **`qgisMaximumVersion=4.99`** in metadata.txt, or QGIS 4 rejects the plugin outright.
- **Scoped enums** (work on PyQt5 >= 5.15 AND PyQt6): `Qt.AlignCenter` to `Qt.AlignmentFlag.AlignCenter`,
  `Qt.UserRole` to `Qt.ItemDataRole.UserRole`, **`Qt.red`/`darkGreen` to `Qt.GlobalColor.red`**
  (lowercase colours are the #1 miss - grep `Qt\.[a-zA-Z]`, not `[A-Z]`), `QDialogButtonBox.Ok` to
  `.StandardButton.Ok`, `QAbstractItemView.SelectRows` to `.SelectionBehavior.*`,
  `QFrame.StyledPanel` to `.Shape.*`, and so on.
- **`.exec_()` to `.exec()`**. Removed: `QRegExp`, `QDesktopWidget`, `QFontMetrics.width()`.
- Static grep cannot reach enums in un-exercised paths - **install and click every dialog/dock**.

## Versioning & release - `reference/publishing-playbook.md` sections 8-9

- Bump `version=` in metadata.txt **and** any in-file `__version__` **and** add a dated `CHANGELOG.md`
  entry (semver). Keep an `[Unreleased]` section. `make tag V=x.y.z` refuses to tag if these disagree.
- Release: gates + build clean, bump + commit + push, tag, CI builds the zip and runs the unit test and
  cuts a GitHub Release, **verify the CI asset**, then manual upload to
  `plugins.qgis.org/plugins/<slug>/version/add/`.

---

## Windows / OSGeo4W

The rest of this file assumes a POSIX shell. These are the Windows differences that bite:

- **Run under QGIS's Python via `python-qgis.bat`, not a PYTHONPATH.** Tests, builds, anything needing
  PyQGIS: `"C:\OSGeo4W\bin\python-qgis.bat" -m unittest ...` (or `-m pytest`, `-m pip`). It sets the full
  QGIS environment. Standalone installer: `...\QGIS x.y\bin\python-qgis.bat`.
- **Git Bash has NO `zip`.** A `zip -qr` build dies with `zip: command not found`. Use
  **`scripts/build_plugin.py`** (stdlib `zipfile`, same manifest and self-verify), or build from
  **WSL / the OSGeo4W shell**. `deploy_local.sh` falls back to the Python builder automatically.
- **cp1252 console produces Unicode "failures" that are LOCAL-ONLY noise.** `print()` or file writes of
  non-ASCII symbols raise `UnicodeEncodeError: 'charmap' codec` on a Windows console but pass on Linux CI
  (UTF-8). Do not chase them; keep runtime output ASCII (`->`, not an arrow glyph). Conversely, an
  `if os.name == 'nt'` branch means the POSIX path is never exercised locally - **run the full
  `unittest discover` and trust Linux CI**, or a Windows-only pass will green a POSIX-only bug.
- **Pin linters EXACTLY to what CI pins.** A newer local `uvx ruff` reformats differently and fails CI's
  `ruff format --check`. Match it: `uvx --from ruff==<ci-version> ruff format .`. Also check whether CI
  has a test-companions job that regenerates fixtures; new tests may need that step run too.
- **Install the plugin locally mid-session:** drop the folder into
  `%APPDATA%\QGIS\QGIS3\profiles\<profile>\python\plugins\<pkg>\`, then in the Python Console:
  `import importlib, qgis.utils as qu; importlib.invalidate_caches(); qu.updateAvailablePlugins();
  qu.loadPlugin('<pkg>'); qu.startPlugin('<pkg>')`. A folder added *after* QGIS started is not seen until
  the import-finder cache is refreshed. For an updated build use `qu.reloadPlugin('<pkg>')`. Cleanest is
  still **Install from ZIP** plus a restart.
- **PowerShell tooling gotchas:** a line starting with a quoted path needs the call operator
  `& "C:\...\x.exe" args`; `$ErrorActionPreference='Stop'` turns a native tool's *stderr* into a fatal
  error - use `'Continue'` and check `$LASTEXITCODE`; and use `Get-Command foo -CommandType Application`
  so a same-named `$PROFILE` *function* is not mistaken for a real executable.

### Publishing extras proven in the field

- **A metadata-only change still needs a version bump** - plugins.qgis.org rejects a duplicate version.
- **`email=` in metadata.txt is PUBLIC** (inside the downloadable zip and on the plugin page). Use a
  non-personal address, e.g. `<name>@users.noreply.github.com`, which satisfies the required field
  without exposing a real inbox. On PyPI, `pyproject authors = [{ name = ... }]` **without** an email
  keeps it off the PyPI page.
- **Uninstallable install:** a plugin dropped in by hand (or via `zipfile.extractall`, which is what
  `deploy_local.sh` does) is NOT removable from the Plugin Manager. For a real install test use
  `pyplugin_installer.instance().installFromZipFile(zip)` so QGIS registers it.
- **Bandit `B310`** (urlopen scheme) on a fixed `https://` constant URL: `# nosec B310` (ruff's is
  `# noqa: S310`). Note QGIS guidance prefers `QgsNetworkAccessManager` over `urllib` for proxy handling.
- **Two-artifact release (a plugin that is also a pip package):** one tag produces the plugin zip
  (manual upload to plugins.qgis.org) **and** a GitHub Release that fires a PyPI publish workflow using
  OIDC **Trusted Publishing** - no stored token; PyPI is updated from GitHub, not `twine`. Wait for CI
  green **before** cutting the release.

---

## When starting any plugin task

1. If **debugging a crash**, read `reference/dock-crash-pitfalls.md` first and get a pristine-backup diagnostic.
2. If **upgrading an old plugin**, do the Qt6 section plus `qgisMaximumVersion`, then gates, then
   build + deploy + click-test.
3. If **publishing**, run gates locally, then `scripts/build_plugin.sh` self-verify, then the release flow.
4. Always **back up the file before a risky refactor** (`cp x.py x.py.orig-<version>`, gitignore `*.orig-*`)
   and **deploy and test in a real QGIS** - compile/flake8 clean is necessary, not sufficient.
