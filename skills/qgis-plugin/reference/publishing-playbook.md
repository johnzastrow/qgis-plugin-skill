# Publishing a QGIS Plugin - Full Process & Playbook

A reusable, end-to-end guide for taking a QGIS Python plugin from a working repo to an approved
listing on **[plugins.qgis.org](https://plugins.qgis.org/)** - including the exact gates the
repository runs, the fixes for the findings you will hit, and the Qt5-to-Qt6 traps that bite on
QGIS 4. Written from real releases; every command here was run for real.

> **Golden rule:** the artifact you upload must be a zip whose **single top-level folder is the
> plugin package name**, containing **every** module the plugin imports, a **LICENSE**, and **no**
> generated files, caches, or VCS directories. Most failed uploads are a packaging problem, not a
> code problem.

> **Ready-made templates** in [`../templates/`](../templates/) - drop them into any plugin repo so
> they all release identically:
> - [`plugin_build.conf`](../templates/plugin_build.conf) - the build manifest. **The only
>   plugin-specific file.**
> - [`Makefile`](../templates/Makefile) - `make check` (ruff + flake8 + bandit + secrets + test),
>   `make build`, `make deploy`, `make tag V=x.y.z`.
> - [`release.yml`](../templates/release.yml) - copy to `.github/workflows/`. On a `v*` tag: runs the
>   gates and unit tests, builds via `scripts/build_plugin.sh`, cuts the GitHub Release with the zip.
> - [`setup.cfg`](../templates/setup.cfg) / [`ruff.toml`](../templates/ruff.toml) - the lint config pair.
>
> All of them delegate the plugin-specific file list to `plugin_build.conf` (section 2), so they are
> byte-identical across every plugin you ship.

---

## 0. TL;DR checklist

```
[ ] metadata.txt valid: name, qgisMinimumVersion, description, version, author, email,
    about, tracker, repository; experimental set intentionally; changelog trimmed
[ ] qgisMaximumVersion=4.99 IF supporting QGIS 4 (else QGIS 4 rejects it as 3.x-only)
[ ] LICENSE file present at repo root AND copied into the zip (GPLv2+-compatible)
[ ] Icons load from a file path (no compiled resources.py / pyrcc5)
[ ] Security gates pass:  bandit (0 high/critical) - detect-secrets (0) - flake8 (clean)
[ ] Qt6-safe: scoped enums, .exec() not .exec_(), no removed APIs (QRegExp/QDesktopWidget/...)
[ ] Build script produces the zip and SELF-VERIFIES subpackages + LICENSE
[ ] Version bumped in ALL places (metadata.txt, CHANGELOG.md, any in-file __version__)
[ ] Zip contains no __pycache__ / .git / *.pyc / .ruff_cache / *.sh
[ ] Installed from ZIP in a real QGIS and every dialog opens without a traceback
```

### Prerequisites (fresh machine)

To run everything below from a clean checkout:

- **git** plus **[`gh`](https://cli.github.com/)** authenticated (`gh auth status`) for tagging and releases.
- **`zip`** and **`unzip`** with a POSIX shell (Linux, macOS, or WSL / the OSGeo4W shell on Windows).
  - **Git Bash for Windows does NOT bundle `zip`** - `build_plugin.sh` dies with
    `zip: command not found`. Use **`scripts/build_plugin.py`** instead: it reads the same
    `plugin_build.conf`, stages and self-verifies identically, and needs only the Python standard
    library. It is also the right choice if you would rather the manifest be parsed than executed.
- **[`uv`](https://docs.astral.sh/uv/)** - runs the linters and scanners in throwaway environments,
  no global installs (`uv run --no-project --with <tool> ...`). Nothing else to `pip install`.
- **A real QGIS** to smoke-test the zip. You only need QGIS's Python or `pyrcc5` if the plugin still
  uses compiled resources - avoid that (section 3).
- **A plugins.qgis.org account** (OSGeo ID) to upload. First-time plugins are reviewed before they go
  live; version updates to an already-approved plugin publish immediately.

---

## 1. Plugin anatomy & `metadata.txt`

A QGIS plugin is a folder on `PYTHONPATH` under `.../python/plugins/<PluginName>/` with an
`__init__.py` exposing `classFactory(iface)`. `metadata.txt` is what the repository and the Plugin
Manager read.

**Mandatory fields** (upload is rejected without them):

```ini
[general]
name=My Plugin
qgisMinimumVersion=3.40
description=One-line summary shown in the manager list.
version=0.6.5
author=Your Name
email=yourname@users.noreply.github.com
about=A fuller paragraph. State any external Python dependencies here, with install guidance.
tracker=https://github.com/you/repo/issues
repository=https://github.com/you/repo
```

**Recommended / high-value:**

```ini
hasProcessingProvider=no
homepage=https://github.com/you/repo
category=Plugins        ; menu placement - see below
icon=icon.svg           ; path INSIDE the zip; svg or png
experimental=False      ; True hides it by default and requires ticking a box on upload
deprecated=False
tags=metadata, catalog, inventory, geopackage
changelog=              ; keep SHORT - last 3 to 5 versions only (see section 8)
server=False
```

**`category`** sets the QGIS menu the plugin's actions go under. The meaningful values are
**`Raster`, `Vector`, `Database`, `Web`**; `Plugins` puts it in the generic Plugins menu. Pick by
what the plugin *is*, not the data it happens to touch - a cross-datatype catalog or DB tool belongs
under `Database` or `Plugins`, not `Vector`.

**`experimental`** - keep `True` while iterating; users must opt in to see it. Flip to `False` for a
stable listing, at which point you no longer need to tick "experimental" on the upload form.

**`email=` is public.** It ships inside the downloadable zip and renders on the plugin page. Use a
non-personal address such as `<name>@users.noreply.github.com`, which satisfies the required field
without exposing a real inbox.

> **QGIS 4 support hinges on `qgisMaximumVersion`.** If you set `qgisMinimumVersion=3.40` and omit
> `qgisMaximumVersion`, QGIS **defaults the max to `3.99`** - and **QGIS 4.x refuses to load the
> plugin** ("This plugin is incompatible... designed for QGIS 3.40 - 3.99"). To span QGIS 3 and 4,
> set it explicitly:
> ```ini
> qgisMinimumVersion=3.40
> qgisMaximumVersion=4.99
> ```
> Only do this once the code is actually Qt6-safe (section 6). Otherwise it loads and then crashes.

---

## 2. Packaging - the manifest-driven build (the #1 lesson)

**The trap:** Plugin Builder ships a `Makefile` plus `pb_tool.cfg` whose file lists are easy to leave
incomplete. If `pb_tool.cfg` has an empty `extra_dirs:` (or the Makefile's `EXTRA_DIRS` loop is the
stock broken `(foreach ...)`), a `make zip` silently omits your subpackages (`db/`, `widgets/`, ...)
and the installed plugin dies with `ModuleNotFoundError`. **Do not trust `make` or `pb_tool` blindly.**

**The fix:** declare what ships in `plugin_build.conf`, and let a self-verifying build script stage it
and **fail loudly** when a required subpackage or the LICENSE is missing.

```bash
cp <skill>/templates/plugin_build.conf .      # then edit
cp -r <skill>/scripts .
bash scripts/build_plugin.sh                  # -> MyPlugin.zip, self-verified
```

The manifest:

```bash
PLUGIN="MyPlugin"                             # top folder in the zip = the package name
FILES=(__init__.py myplugin.py myplugin_dockwidget.py metadata.txt icon.svg LICENSE)
DIRS=(db widgets icons i18n)                  # every imported subpackage and asset dir
VERIFY=(db/ widgets/ icons/ LICENSE metadata.txt)
```

What the build enforces, so you cannot ship a bad zip by accident:

- exactly **one top-level folder**, named `PLUGIN`;
- every `VERIFY` entry, plus `LICENSE` and `metadata.txt`, present in the built zip;
- **no** `__pycache__`, `.git`, `*.pyc`, `.ruff_cache`, `__MACOSX`, compiled `resources.py`, `docs/`,
  or archives;
- **no compiled binaries** (`.exe`, `.dll`, `.so`, `.dylib`, `.pyd`, ... ) - QGIS bans them;
- **no `*.sh`** - the repository's security scanner flags shell-script installers (see section 4).
  Override with `ALLOW_SHELL_SCRIPTS=1` only with a reviewed reason;
- total size under the **20 MB** repository limit.

Notes that cost real debugging time:

- **Top-level folder = the plugin package name.** If you vendor a third-party package under `libs/`,
  do NOT name the top folder the same as the vendored package, or it shadows it at import time.
- **`set -o pipefail` plus `grep -q`**: `grep -q` exits on the first match and closes the pipe; the
  upstream `unzip` then dies with SIGPIPE (141) and `pipefail` fails the whole line even though the
  match succeeded. Capture the listing into a variable first, then grep the variable. (The shipped
  script already does this - keep it that way if you edit it.)
- **Keep the CI build and the local build identical.** Because both read `plugin_build.conf`, they
  cannot drift. If you hand-roll a CI file list instead, you will eventually get "works in CI, broken
  locally" or the reverse.

**Vendoring a zero-dependency package.** If your plugin wraps a pure-Python package, copy it into
`libs/<pkg>` inside the plugin so it installs with **no pip step**, cross-platform. Add `libs` to
`DIRS`. This only applies when there is an external package to vendor; a plain Plugin-Builder
plugin's own `db/` and `widgets/` code just needs to be listed in `DIRS`.

---

## 3. Icons without compiled Qt resources

**Avoid the `resources.qrc` to `resources.py` (pyrcc5) path.** It adds a build-time compiler
dependency, and QGIS's own guidance says **"no generated files left in the repository."** It is also
fragile: strip the `from .resources import *` side-effect import (an aggressive `autoflake` will) and
every `:/plugins/...` icon silently fails to load.

**Do this instead** - load icons from a plain file path relative to the plugin directory:

```python
self.plugin_dir = os.path.dirname(__file__)
...
icon_path = os.path.join(self.plugin_dir, 'icons', 'icon.svg')   # not ':/plugins/Foo/icons/icon.svg'
action = QAction(QIcon(icon_path), text, parent)
```

Then delete `resources.qrc` and `resources.py`, drop the `pyrcc5` step from CI and the build, and
remove `from .resources import *`. Ship the `icons/` folder in the zip via `DIRS`. (If you keep
compiled resources anyway, `pyrcc5` is not in modern PyQt5 wheels standalone, but
`uv run --no-project --with pyqt5 -- pyrcc5 -o resources.py resources.qrc` works.)

---

## 4. The plugins.qgis.org gates - Bandit, Secrets, flake8

The repository runs automated checks on upload. **Critical Bandit findings and detected secrets
BLOCK the plugin until resolved.** flake8 runs too - treat it as authoritative for style. Run them
locally first, no install needed, via `uv`:

```bash
# Security (Bandit) - aim for 0 HIGH/MEDIUM; HIGH/critical is a hard block
uv run --no-project --with bandit bandit -r . -x ./test,./tests,./.git,./help,./docs

# Secrets - must be 0
uv run --no-project --with detect-secrets detect-secrets scan --all-files

# Style/lint - the authoritative pre-publish check
uv run --no-project --with flake8 flake8 .
```

Or just `make check`, which runs all of these plus the unit tests.

### Fixing the findings you will actually hit

| Finding | What it means | Fix |
|---|---|---|
| **B608** SQL injection | An identifier (table/column) is f-string-interpolated into SQL (parameters `?` cannot bind identifiers) | Validate against a strict allowlist: `re.match(r'^[A-Za-z_][A-Za-z0-9_]*$', name)`; then `# nosec B608 - validated identifier` |
| **B314 / B405** XXE | `xml.etree.ElementTree.parse` on untrusted XML | Use `defusedxml`, **or**, if it is only local user-selected files with no external entities: `# nosec B314 - local sidecar, no external entities` |
| **B404 / B603 / B607** subprocess | Shelling out (e.g. `df` for a mount point) with a partial path | Best: remove it. The Unix mount point is pure-Python - walk up with `os.path.ismount()`. Otherwise `# nosec` with a justification |
| **B310** urlopen scheme | `urllib.request.urlopen(url)` - bandit cannot prove `url` is not `file:` or a custom scheme | If the URL is a **fixed `https://` constant**, it is a reviewed non-issue: `# nosec B310 - fixed https URL`. If it is user- or config-derived, validate the scheme is `https` first. Ruff's equivalent is `S310`; a line can carry both: `# noqa: S310  # nosec B310`. Note QGIS's guideline (section 10) prefers `QgsNetworkAccessManager` over `urllib` - a zero-dependency plugin may justify `urllib` in the `about` text, but reviewers do look for it |
| **B110** try/except/pass, **B112** try/except/continue | Silently swallowed exceptions | Low severity, rarely blocks. Prefer logging the exception; at minimum use `except Exception:`, not a bare `except:`. Use the *correct* code - B110 is `pass`, B112 is `continue` |
| **Secret: "Hex High Entropy String" in `.ruff_cache/CACHEDIR.TAG`** | A **false positive** - the ruff cache's magic signature | `.gitignore` the caches (`.ruff_cache/`, `__pycache__/`) and `rm -rf .ruff_cache` before scanning. `make secrets` does this for you |

**Shell-script installers are flagged.** A `*.sh` that downloads a binary and moves it into a system
path is exactly the pattern the security scanner catches, and it is a realistic cause of rejection.
Do not ship installer shell scripts inside the plugin. Put the guidance in the README and give an
in-app link instead:

```python
QDesktopServices.openUrl(QUrl("https://github.com/owner/tool/releases"))
```

The build scripts reject `*.sh` inside the zip by default for exactly this reason.

**Secrets, real ones:** never commit tokens or passwords. A `detect-secrets` hit that is not a cache
artifact is a real problem - rotate the credential and purge it from history.

**Bandit `# nosec`** is the accepted way to acknowledge a reviewed non-issue - always with the test id
and a one-line justification (`# nosec B608 - identifier validated above`). Do not blanket-suppress.

---

## 5. Linting - ruff to iterate, flake8 to verify

Iterate fast with **ruff** (`ruff check --fix`), but **run flake8 before publishing** - they differ.
ruff does not implement the pycodestyle continuation-indent checks (`E12x`) or `W503`/`W504`, and
gates a few `E3xx`/`E265` behind `--preview`. Keep a shared config so ruff mirrors flake8 as closely
as it can: see [`../templates/setup.cfg`](../templates/setup.cfg) (flake8, authoritative) and
[`../templates/ruff.toml`](../templates/ruff.toml) (the fast local mirror).

**Pin ruff to exactly what CI pins.** A newer local ruff formats differently and fails CI's
`ruff format --check`:

```bash
uvx --from ruff==<the-version-CI-uses> ruff format .
```

Bulk-fix unused imports with `autoflake` - but it will happily delete a **side-effect star import**
(`from .resources import *`); guard it, or better, remove the compiled-resources approach entirely
(section 3). Fix bare excepts mechanically:

```bash
sed -i -E 's/(^[[:space:]]*)except:[[:space:]]*$/\1except Exception:/' file.py
```

---

## 6. Qt5 to Qt6 compatibility (this is what breaks on QGIS 4)

**QGIS 3.x is PyQt5; QGIS 4.x is PyQt6.** A plugin supporting both must run on both. (And remember
`qgisMaximumVersion=4.99` from section 1, or QGIS 4 will not even *try* to load it.) The #1 cause of
"installs fine, crashes when I open a panel" is **unscoped Qt enums**, which PyQt6 removed. Use the
**scoped** forms - they work on PyQt5 >= 5.15 (which QGIS 3.28/3.34/3.40 ship) **and** PyQt6:

| Qt5-only (crashes on Qt6) | Scoped (works on both) |
|---|---|
| `Qt.AlignCenter`, `Qt.AlignLeft` | `Qt.AlignmentFlag.AlignCenter` |
| `Qt.UserRole`, `Qt.DisplayRole` | `Qt.ItemDataRole.UserRole` |
| `Qt.Horizontal` / `Qt.Vertical` | `Qt.Orientation.Horizontal` |
| `Qt.Checked` / `Qt.Unchecked` | `Qt.CheckState.Checked` |
| `Qt.RightDockWidgetArea` | `Qt.DockWidgetArea.RightDockWidgetArea` |
| `Qt.red`, `Qt.darkGreen`, `Qt.darkYellow` (**lowercase** colours) | `Qt.GlobalColor.red` |
| `Qt.ItemIsEditable` | `Qt.ItemFlag.ItemIsEditable` |
| `QDialogButtonBox.Ok` / `.Cancel` | `QDialogButtonBox.StandardButton.Ok` |
| `QAbstractItemView.SelectRows` | `QAbstractItemView.SelectionBehavior.SelectRows` |
| `QAbstractItemView.SingleSelection` | `QAbstractItemView.SelectionMode.SingleSelection` |
| `QAbstractItemView.NoEditTriggers` | `QAbstractItemView.EditTrigger.NoEditTriggers` |
| `QFrame.StyledPanel` / `NoFrame` | `QFrame.Shape.StyledPanel` |
| `QFont.Bold` | `QFont.Weight.Bold` |
| `QHeaderView.Stretch` | `QHeaderView.ResizeMode.Stretch` |

**Other Qt6 removals to sweep for:** `dialog.exec_()` becomes **`dialog.exec()`** (both work on
PyQt5 >= 5.15); `QRegExp` becomes `QRegularExpression`; `QDesktopWidget` / `QApplication.desktop()`
become the `screen()` APIs; `QFontMetrics.width()` becomes `.horizontalAdvance()`;
`layout.setMargin()` becomes `.setContentsMargins()`; `.toPyObject()` is gone.

**QGIS-4 API relocations - the silent-default trap (not Qt, same failure shape):** some QGIS
attributes moved onto sub-objects across 3 to 4. The danger is that
`getattr(qgis_obj, 'oldAttr', default)` **silently returns `default`** when the attribute is gone, so
the plugin runs but ignores the real setting - no exception, no crash, just wrong output. When
porting to QGIS 4, grep for `getattr(<qgis object>, '...', ...)` and prefer direct access (let it
raise) or an explicit `hasattr` branch per QGIS version, so a rename surfaces loudly instead of
defaulting. See Pitfall 7 in `dock-crash-pitfalls.md`.

**Find them fast:**

```bash
FILES=$(echo *.py widgets/*.py db/*.py processors/*.py)
# BOTH cases - [a-zA-Z], not [A-Z]: the GlobalColor constants (Qt.red, Qt.darkGreen, ...) are
# lowercase and are the #1 thing a caps-only grep misses.
grep -rhoE "Qt\.[a-zA-Z][a-zA-Z0-9]+" $FILES | grep -vE "Qt\.(QtCore|QtGui|QtWidgets|QtXml)" \
  | sort | uniq -c | sort -rn
grep -rnE "\.exec_\(|QRegExp|QDesktopWidget|\.setMargin\(|\.toPyObject\(" $FILES
```

**Fix in bulk** with word-boundary sed (`\b`), then re-grep for residuals and `py_compile` every file.
Caveat: static grep cannot reach enums only referenced in code paths you do not exercise - **install
and click through every dialog** to flush the rest.

---

## 7. Testing under QGIS's Python

Unit tests that do not import `qgis` or `PyQt` run anywhere - wire those into CI. Anything touching
QGIS must run under **QGIS's own Python**:

```bash
export QT_QPA_PLATFORM=offscreen                     # no display
export PYTHONPATH=/usr/share/qgis/python:/usr/lib/python3/dist-packages
python3 -m pytest test/test_something_qgis.py
```

On Windows use `python-qgis.bat` from the OSGeo4W shell, which sets the environment for you; on macOS
use the Python bundled inside `QGIS.app`. `py_compile` every shipped `.py` as a cheap syntax gate:

```bash
python -c "import py_compile,glob; [py_compile.compile(f,doraise=True) for f in glob.glob('**/*.py',recursive=True) if '/test' not in f]; print('OK')"
```

See `dock-crash-pitfalls.md` ("Local testing") for the crash-catching integration tier.

**Install-from-ZIP smoke test.** In QGIS: *Plugins > Manage and Install Plugins > Install from ZIP >*
the built zip. QGIS caches imported modules, so when **reinstalling a new build**, uninstall the old
copy first (or reinstall over it and toggle the plugin off and on) or you will keep running the old
code. Then exercise **every** panel and dialog - Qt6 enum crashes (section 6) only fire on the code
path that actually runs.

---

## 8. Versioning & changelog

Bump the version in **every** place it lives, or the manager and the code disagree:

- `metadata.txt` -> `version=`
- `CHANGELOG.md` -> a new `## [x.y.z] - YYYY-MM-DD` section (CI often parses this for release notes)
- any in-file `__version__` (easy to leave stale - grep for it)

`make tag V=x.y.z` refuses to tag when these disagree, which is the cheapest possible guard.

**Trim the `metadata.txt` `changelog=` field to the last 3 to 5 versions** and point to the full log.
The Plugin Manager renders that field, and a 200-line history is noise. Keep the complete history in
`CHANGELOG.md`.

**A metadata-only change still needs a version bump** - plugins.qgis.org rejects a duplicate version.

---

## 9. Release - CI build + manual upload

plugins.qgis.org has **no auto-publish** (unlike PyPI Trusted Publishing). End-to-end, from a clean
checkout on any machine:

```bash
# 0. gates + build, all local (sections 4 and 5). Fix until clean.
make check
make build

# 1. bump the version everywhere (section 8), then commit and push
git add -A && git commit -m "vX.Y.Z: ..." && git push origin main

# 2. tag -> GitHub Actions runs the gates and unit tests, builds the zip, cuts a Release
make tag V=X.Y.Z
gh run watch "$(gh run list --workflow=release.yml -L1 --json databaseId -q '.[0].databaseId')" --exit-status

# 3. VERIFY the CI-built asset before uploading (metadata + completeness)
gh release download vX.Y.Z -p "*.zip" -O /tmp/rel.zip
unzip -p /tmp/rel.zip '<Plugin>/metadata.txt' | grep -E "^version=|^qgisM|^experimental="
unzip -l /tmp/rel.zip | grep -icE "resources.py|__pycache__|\.git|\.sh$"   # must be 0
```

4. **Upload** the zip at `https://plugins.qgis.org/plugins/<slug>/version/add/`. For a first-time
   plugin, use the repository's *"add a plugin"* page instead; both need your OSGeo login. Tick
   **experimental** if the metadata says so. The reviewer does light testing that it installs without
   crashing QGIS; version bumps to an already-approved plugin go live immediately.

### If the plugin is also a pip package

Ship **two independent artifacts** from one tag:

- **the plugin zip** - built by `scripts/build_plugin.sh`, uploaded manually to plugins.qgis.org as above.
- **the PyPI wheel** - a GitHub **Release** (`gh release create vX.Y.Z --target main ...`) triggers a
  `publish-pypi.yml` workflow which builds and publishes to PyPI via **Trusted Publishing** (OIDC, no
  stored token). One-time PyPI setup: Account > Publishing > add the GitHub trusted publisher
  (owner / repo / workflow / environment).

Wait for CI green **before** cutting the release. Verify the PyPI side with
`curl -s -o /dev/null -w '%{http_code}' https://pypi.org/pypi/<pkg>/X.Y.Z/json` returning `200` - the
aggregate `/pypi/<pkg>/json` endpoint is CDN-cached and lags.

If there is no release workflow, build the zip locally and attach it:
`gh release create <tag> ... the.zip`.

---

## 10. QGIS official requirements - quick reference

From the [plugin repository guidelines](https://plugins.qgis.org/publish/):

- License **compatible with GPLv2 or later**; respect bundled libraries' licenses.
- **No binaries.** Package **under 20 MB**.
- Metadata has valid **homepage, repository, tracker, license** links, and at least minimal docs.
- **No generated files** in the repo (`ui_*.py`, `resources_rc.py`, generated help).
- **No `__MACOSX`, `.git`, `__pycache__`** or hidden directories in the zip.
- Use **`QgsNetworkAccessManager`**, not `urllib` or `requests` (correct proxy handling).
- Public source repository, not just a zip; cross-platform (Windows / Linux / macOS).

---

## 11. Common pitfalls (the greatest hits)

- **`make` / `pb_tool` drops subpackages**, producing `ModuleNotFoundError` on install. Use the
  manifest-driven build and let it self-verify.
- **Compiled resources fail to load** after an import cleanup - missing icons, `:/plugins/...` errors.
  Switch to file-path icons.
- **Missing `qgisMaximumVersion`** - QGIS 4 reports "incompatible ... designed for 3.40 - 3.99" and
  will not load it at all. Set `qgisMaximumVersion=4.99` after making the code Qt6-safe.
- **Unscoped Qt enums** - crashes only when a panel or dialog opens on QGIS 4. Scope them all.
- **`.exec_()`** - `AttributeError` on PyQt6. Use `.exec()`.
- **Shipping a `*.sh` installer** - flagged by the security scanner. README guidance plus an in-app link.
- **`.ruff_cache/CACHEDIR.TAG`** flagged as a secret - gitignore and remove caches before scanning.
- **CRLF line endings** in config files (Windows edits) - `sed` patterns silently fail to match.
  Account for `\r` or normalize.
- **Stale `__version__`** in a source file while `metadata.txt` moved on.
- **Bloated `changelog=`** in metadata.txt.
- **`set -o pipefail` plus `grep -q`** false failures in build scripts - capture to a variable first.
