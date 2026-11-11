# Changelog

All notable changes to this skill are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is
[semver](https://semver.org/).

## [Unreleased]

## [1.0.3] - 2026-11-11

### Fixed
- `templates/Makefile`: the secrets gate failed on the template itself. detect-secrets reads a
  make target named `secrets:` as a secret keyword and flags the recipe lines under it (two
  "Secret Keyword" findings in every plugin repo that copied the template). The target is now
  `leak-scan` (`make check` runs it).
- `templates/Makefile` and `templates/release.yml`: the secrets step could never fail, because
  `detect-secrets scan` exits 0 even when it finds something. Both now parse the JSON and fail
  on a non-empty `results`.
- `templates/Makefile` and `templates/release.yml`: the secrets scan now excludes `.git/`. With
  `--all-files` it scanned `.git/FETCH_HEAD`, whose quoted commit hash is a "Hex High Entropy
  String" on every CI checkout. The old gate hid this because it could never fail.
- `SKILL.md` and `reference/publishing-playbook.md`: document these pitfalls; `make secrets`
  references updated to `make leak-scan`.

### Added
- `tests/smoke_build.sh`: regression checks that the Makefile template has no `secrets:` target
  and that both template gates check the detect-secrets results and exclude `.git/`.

## [1.0.2] - 2026-07-22

### Added
- `.github/workflows/release.yml` — this repository's own release automation. On a `v*` tag it
  runs the gates, refuses to proceed unless the tag agrees with `marketplace.json` and
  `CHANGELOG.md`, builds the Claude-Desktop-installable skill zip, verifies that artifact, and
  cuts the GitHub Release using the CHANGELOG section as the notes. A manual
  `workflow_dispatch` runs everything except the release step as a dry run. Distinct from
  `skills/qgis-plugin/templates/release.yml`, which is the template for consumers' *plugin* repos.
- `tests/smoke_build.sh` — regression guard for the build tooling. Builds a synthetic plugin with
  both builders, asserts they emit identical file sets, and asserts every failure mode is still
  rejected (shell script, compiled binary, path traversal, unsafe `PLUGIN`, missing LICENSE,
  unshipped `VERIFY` entry, nonexistent file) plus that the `ALLOW_SHELL_SCRIPTS` override still
  works. Verified to have teeth by mutation testing: removing a check turns it red.

### Changed
- Bumped the pinned GitHub Actions in both the repo's own workflow and
  `templates/release.yml` (`checkout` v4 to v7, `setup-python` v5 to v7, `setup-uv` v5 to the
  exact pin v9.0.0). The old v4/v5 pins target Node 20, which GitHub has deprecated and now
  force-runs on Node 24 — a warning the template would otherwise propagate to everyone who
  copies it. `setup-uv` is pinned exactly because it publishes no floating major tag past v7, so
  `@v9` does not resolve. Also disabled uv's cache in both, since with no lockfile to key on it
  would never invalidate.

## [1.0.1] - 2026-07-22

### Changed
- `templates/release.yml` now carries the ruff version in a single `RUFF_VERSION` workflow
  env var instead of hardcoding it in the lint step. The pin is still exact — a newer ruff
  formats differently and fails a `ruff format --check` that passed locally — but it is now
  an obvious knob to set rather than a buried value that reads as a recommendation.
  `templates/ruff.toml` and the publishing playbook point at that one location.

## [1.0.0] - 2026-07-22

First public release. Extracted from a personal Claude configuration and made
plugin-agnostic.

### Added
- `templates/plugin_build.conf` — a build manifest, so the build scripts need no per-plugin
  editing. Previously the build script was hardcoded to a single plugin.
- `scripts/build_plugin.py` — a Python-stdlib build with no dependency on the `zip` binary, for
  Git Bash on Windows. Parses the manifest rather than executing it.
- `templates/Makefile`, `templates/release.yml`, `templates/setup.cfg`, `templates/ruff.toml` —
  the project files the publishing playbook referenced but did not ship.
- Build-time enforcement of the plugins.qgis.org rules that were previously prose only: exactly one
  top-level folder, no compiled binaries, no archives, and the 20 MB package limit.
- Pitfall 7 in the crash reference: a removed QGIS-4 attribute hidden behind
  `getattr(obj, 'x', default)`, which silently returns the default and produces wrong output with no
  crash and no traceback.

### Fixed
- The build script shipped an installer shell script inside the plugin zip and omitted `*.sh` from
  its forbidden-entry check, directly contradicting the skill's own guidance that the
  plugins.qgis.org security scanner flags exactly that pattern. Shell scripts are now rejected by
  default (`ALLOW_SHELL_SCRIPTS=1` to override with a reviewed reason).
- `deploy_local.sh` took a plugin name argument that was then ignored by the hardcoded build, and
  `SKILL.md` documented a signature the script did not accept. Both now read the manifest.
- Dead links to a `templates/` directory that did not exist.
- An unterminated code fence at the end of the publishing playbook.

### Changed
- Genericised: references to private plugin repositories, one machine's QGIS and Python versions, a
  specific pinned linter version, and a personal email were replaced with portable guidance.
- Removed all emoji in favour of plain ASCII.
