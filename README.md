# qgis-plugin-skill

An [Agent Skill](https://agentskills.io/specification) for **authoring, debugging, packaging and
publishing QGIS Python plugins** — the operational knowledge that is not in the QGIS docs because you
only learn it by shipping.

It teaches an AI coding agent (Claude Code, Claude Desktop, or anything that reads the skill format)
the things that actually cost time on a QGIS plugin:

- **The crash class.** QGIS segfaults are C++ object-lifetime bugs, and `try/except` cannot catch
  them. The skill covers the specific ones: dangling symbols from renderer containers, reading layers
  during project-load teardown, `QListWidget.clear()` with a live selection, `showEvent`-driven work.
- **The packaging trap.** `make` / `pb_tool` silently drop subpackages and the installed plugin dies
  with `ModuleNotFoundError`. Ships a manifest-driven, self-verifying build instead.
- **The plugins.qgis.org gates.** Bandit, detect-secrets and flake8, with the fixes for the findings
  you will actually hit — including the shell-script-installer pattern that gets plugins rejected.
- **Qt5 to Qt6 (QGIS 4).** The scoped-enum table, the removed APIs, and the `qgisMaximumVersion`
  setting without which QGIS 4 refuses to load your plugin at all.
- **Windows / OSGeo4W.** `python-qgis.bat`, the missing `zip` in Git Bash, cp1252 console noise that
  looks like test failures but is not.

## Contents

```
skills/qgis-plugin/
├── SKILL.md                            operational index; golden rules and quick-reference tables
├── reference/
│   ├── dock-crash-pitfalls.md          the segfault class, with a diagnostic method
│   ├── publishing-playbook.md          end-to-end: metadata, packaging, gates, Qt6, release
│   └── qgis4-api-notes.md              PyQGIS 4 API changes and headless-rendering crashers
├── scripts/
│   ├── build_plugin.sh                 self-verifying zip builder (bash + zip)
│   ├── build_plugin.py                 same build, Python stdlib only (Windows / Git Bash)
│   └── deploy_local.sh                 build and install into a local QGIS profile
└── templates/
    ├── plugin_build.conf               the build manifest — the only plugin-specific file
    ├── Makefile                        make check / build / deploy / tag
    ├── release.yml                     GitHub Actions: gates, build, Release on a v* tag
    ├── setup.cfg                       flake8 (authoritative style gate)
    └── ruff.toml                       ruff (fast local mirror)
```

## Install

### Claude Code — as a plugin (recommended)

```
/plugin marketplace add johnzastrow/qgis-plugin-skill
/plugin install qgis-plugin@qgis-plugin-skill
```

### Claude Code — as a plain skill

```bash
git clone https://github.com/johnzastrow/qgis-plugin-skill
cp -r qgis-plugin-skill/skills/qgis-plugin ~/.claude/skills/
```

Project-scoped instead of global: copy into `.claude/skills/` inside the repo.

### Claude Desktop / claude.ai

Zip the skill directory and upload it as a custom skill:

```bash
cd skills && zip -r qgis-plugin.zip qgis-plugin
```

See [Using skills in Claude](https://support.claude.com/en/articles/12512180-using-skills-in-claude).

## Use

The skill triggers on its own for QGIS plugin work — mentioning `metadata.txt`, a crash in a dock
widget, `plugins.qgis.org`, or `qgisMinimumVersion` is enough. You can also ask for it by name:

> Use the qgis-plugin skill — QGIS closes when I click Refresh in my dock panel.

> Get this plugin ready to upload to plugins.qgis.org.

## Using the build tooling directly

The scripts are useful with or without an AI agent. Copy them into a plugin repo, then declare what
ships in one manifest:

```bash
cp -r <skill>/skills/qgis-plugin/scripts .
cp <skill>/skills/qgis-plugin/templates/plugin_build.conf .
$EDITOR plugin_build.conf
```

```bash
PLUGIN="MyPlugin"                             # top folder in the zip = the package name
FILES=(__init__.py myplugin.py metadata.txt icon.svg LICENSE)
DIRS=(db widgets icons i18n)                  # every imported subpackage and asset dir
VERIFY=(db/ widgets/ icons/ LICENSE metadata.txt)
```

```bash
bash scripts/build_plugin.sh     # -> MyPlugin.zip, self-verified
bash scripts/deploy_local.sh     # build + install into the local QGIS profile
python scripts/build_plugin.py   # same build without the zip binary (Windows / Git Bash)
```

The build **fails loudly** rather than shipping a bad zip. It enforces exactly one top-level folder
named `PLUGIN`; every `VERIFY` entry plus `LICENSE` and `metadata.txt` present; no `__pycache__`,
`.git`, compiled `resources.py`, `docs/` or archives; no compiled binaries; no `*.sh` (the
plugins.qgis.org scanner flags installer shell scripts); and a total size under the 20 MB limit.

## Contributing

The value here is field-tested specifics, so the bar for additions is: **it happened, and the generic
advice would not have prevented it.** A good addition names the symptom, the cause and the fix.

Please keep contributions plugin-agnostic — no references to a private repo, and no assertions about
one machine's QGIS or Python version.

## License

MIT — see [LICENSE](LICENSE).
