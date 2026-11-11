#!/usr/bin/env python3
"""Build a plugins.qgis.org-ready QGIS plugin zip from plugin_build.conf.

Functional twin of build_plugin.sh, using only the Python standard library so it
works where the zip toolchain does not - notably **Git Bash on Windows, which
does not bundle `zip`**. Also usable from cmd.exe, PowerShell, the OSGeo4W shell,
or QGIS's own Python.

    python scripts/build_plugin.py [-c plugin_build.conf] [-o out.zip]

The manifest is PARSED, not executed, so this path is also the right one when you
want to build from a manifest you have not audited.
"""

from __future__ import annotations

import argparse
import os
import re
import shlex
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

MAX_ZIP_BYTES = 20 * 1024 * 1024  # plugins.qgis.org package limit

PRUNE_DIRS = {
    "__pycache__", ".git", ".ruff_cache", ".pytest_cache",
    ".mypy_cache", "__MACOSX", ".hg", ".svn",
}
PRUNE_FILE_SUFFIXES = (".pyc", ".pyo")
PRUNE_FILE_NAMES = {".DS_Store"}

BINARY_SUFFIXES = (
    ".exe", ".dll", ".so", ".dylib", ".pyd", ".a", ".o", ".jar", ".class", ".bin",
)

FORBIDDEN_BASE = (
    r"__pycache__|\.git/|\.pyc|\.pyo|\.ruff_cache|__MACOSX|"
    r"resources\.py|/docs/|\.tar\.gz|\.tgz|\.rar|\.7z"
)

ASSIGN_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$")


class BuildError(Exception):
    """A build precondition or verification failed."""


# --------------------------------------------------------------------------- #
# Manifest parsing - a deliberately restricted bash subset, never executed.
# --------------------------------------------------------------------------- #
def parse_manifest(path: Path) -> dict:
    """Parse NAME="value" and NAME=(a b c) assignments. No substitution, no eval."""
    text = path.read_text(encoding="utf-8")
    values: dict = {}
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            i += 1
            continue
        m = ASSIGN_RE.match(line)
        if not m:
            i += 1
            continue
        name, rest = m.group(1), m.group(2).strip()
        if rest.startswith("("):
            # Collect through the closing paren, which may be several lines down.
            buf = rest[1:]
            while ")" not in buf and i + 1 < len(lines):
                i += 1
                buf += "\n" + lines[i]
            buf = buf.split(")", 1)[0]
            values[name] = shlex.split(buf, comments=True)
        else:
            parts = shlex.split(rest, comments=True)
            values[name] = parts[0] if parts else ""
        i += 1
    return values


def check_rel(entry: str, field: str) -> None:
    """Reject anything that could escape the manifest directory."""
    if not entry:
        raise BuildError(f"{field} contains an empty entry")
    if entry.startswith(("/", "~")) or (os.name == "nt" and re.match(r"^[A-Za-z]:", entry)):
        raise BuildError(f"{field} entry {entry!r} must be relative to the manifest directory")
    if ".." in Path(entry).parts:
        raise BuildError(f"{field} entry {entry!r} must not contain '..'")


def find_manifest(explicit: str | None) -> Path:
    if explicit:
        p = Path(explicit)
        if not p.is_file():
            raise BuildError(f"manifest not found: {p}")
        return p.resolve()
    here = Path(__file__).resolve().parent
    for cand in (Path.cwd() / "plugin_build.conf", here.parent / "plugin_build.conf"):
        if cand.is_file():
            return cand.resolve()
    raise BuildError(
        "no plugin_build.conf found (looked in ./ and ../ of the script; pass -c PATH).\n"
        "       Start from templates/plugin_build.conf in this skill."
    )


# --------------------------------------------------------------------------- #
# Staging
# --------------------------------------------------------------------------- #
def prune(stage: Path) -> None:
    for dirpath, dirnames, filenames in os.walk(stage, topdown=True):
        for d in [d for d in dirnames if d in PRUNE_DIRS]:
            shutil.rmtree(Path(dirpath) / d, ignore_errors=True)
            dirnames.remove(d)
        for fn in filenames:
            if fn.endswith(PRUNE_FILE_SUFFIXES) or fn in PRUNE_FILE_NAMES:
                (Path(dirpath) / fn).unlink(missing_ok=True)


def assert_no_binaries(stage: Path) -> None:
    hits = [
        str(p.relative_to(stage))
        for p in stage.rglob("*")
        if p.is_file() and p.suffix.lower() in BINARY_SUFFIXES
    ]
    if hits:
        raise BuildError(
            "compiled binaries staged - plugins.qgis.org bans binaries:\n  "
            + "\n  ".join(hits)
        )


def build(root: Path, plugin: str, files: list, dirs: list, out: Path) -> list:
    work = Path(tempfile.mkdtemp(prefix="qgisplugin-"))
    try:
        stage = work / plugin
        stage.mkdir(parents=True)

        for f in files:
            src = root / f
            if not src.is_file():
                raise BuildError(f"FILES entry {f!r} does not exist (relative to {root})")
            dst = stage / f
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)

        for d in dirs:
            src = root / d
            if not src.is_dir():
                raise BuildError(f"DIRS entry {d!r} does not exist (relative to {root})")
            shutil.copytree(src, stage / d)

        prune(stage)
        assert_no_binaries(stage)

        out.parent.mkdir(parents=True, exist_ok=True)
        if out.exists():
            out.unlink()
        names = []
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
            for p in sorted(stage.rglob("*")):
                if p.is_file():
                    arc = f"{plugin}/{p.relative_to(stage).as_posix()}"
                    z.write(p, arc)
                    names.append(arc)
        return names
    finally:
        shutil.rmtree(work, ignore_errors=True)


# --------------------------------------------------------------------------- #
# Self-verify
# --------------------------------------------------------------------------- #
def verify(out: Path, plugin: str, names: list, want: list,
           forbidden_extra: str, allow_sh: bool) -> None:
    tops = {n.split("/", 1)[0] for n in names}
    if tops != {plugin}:
        raise BuildError(
            f"zip must contain exactly one top-level folder named {plugin!r}, "
            f"found: {sorted(tops)}"
        )

    required = list(want) + ["LICENSE", "metadata.txt"]
    for entry in required:
        needle = f"{plugin}/{entry}"
        if not any(n.startswith(needle) or needle in n for n in names):
            raise BuildError(
                f"{entry!r} missing from the built zip - check FILES/DIRS in the manifest"
            )

    pattern = FORBIDDEN_BASE
    if not allow_sh:
        pattern += r"|\.sh$"
    if forbidden_extra:
        pattern += "|" + forbidden_extra
    rx = re.compile(pattern, re.IGNORECASE)
    hits = [n for n in names if rx.search(n)]
    if hits:
        raise BuildError(
            "forbidden entries in the zip:\n"
            + "\n".join(f"  {n}\n      -> {forbidden_reason(n)}" for n in hits)
        )

    size = out.stat().st_size
    if size >= MAX_ZIP_BYTES:
        raise BuildError(
            f"zip is {size // 1048576} MB - plugins.qgis.org limits packages to 20 MB"
        )


def forbidden_reason(name: str) -> str:
    """Which packaging rule a forbidden zip entry breaks (same wording as build_plugin.sh)."""
    low = name.lower()
    base = low.rsplit("/", 1)[-1]  # same match as FORBIDDEN_BASE: any name ending resources.py
    if any(k in low for k in ("__pycache__", ".ruff_cache", "__macosx")) or low.endswith((".pyc", ".pyo")):
        return "cache or bytecode - strip it (it should never be in DIRS/FILES output)"
    if ".git/" in low:
        return "version-control data - build from a clean tree"
    if base.endswith("resources.py"):
        return (
            "plugins.qgis.org bans files named resources.py (compiled Qt resources), even a\n"
            "            hand-written module - rename the module and load icons from file paths"
        )
    if "/docs/" in low:
        return "docs/ belongs in the repo, not the plugin zip"
    if low.endswith(".sh"):
        return (
            "shell script - flagged by the plugins.qgis.org security scanner; put installer\n"
            "            guidance in the README and link out with QDesktopServices.openUrl (or set\n"
            "            ALLOW_SHELL_SCRIPTS=1 in the manifest after review)"
        )
    if low.endswith((".tar.gz", ".tgz", ".rar", ".7z")):
        return "nested archive - plugins.qgis.org rejects archives in the zip"
    return "matches FORBIDDEN_EXTRA in the manifest"


def read_version(root: Path) -> str:
    meta = root / "metadata.txt"
    if not meta.is_file():
        return ""
    for line in meta.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("version="):
            return line.split("=", 1)[1].strip()
    return ""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("-c", "--conf", help="path to plugin_build.conf")
    ap.add_argument("-o", "--out", help="output zip path")
    args = ap.parse_args()

    try:
        conf = find_manifest(args.conf)
        root = conf.parent
        m = parse_manifest(conf)

        plugin = m.get("PLUGIN", "")
        if not plugin:
            raise BuildError(f"PLUGIN is not set in {conf}")
        if not re.fullmatch(r"[A-Za-z0-9_-]+", plugin):
            raise BuildError(
                f"PLUGIN={plugin!r} must be a bare package name ([A-Za-z0-9_-] only) - "
                "it is the top folder in the zip and a Python import name"
            )

        files = m.get("FILES") or []
        dirs = m.get("DIRS") or []
        want = m.get("VERIFY") or []
        if not files:
            raise BuildError(f"FILES is empty in {conf} - list every module the plugin imports")
        for f in files:
            check_rel(f, "FILES")
        for d in dirs:
            check_rel(d, "DIRS")

        out = Path(args.out or m.get("OUT") or f"{plugin}.zip")
        if not out.is_absolute():
            out = root / out

        names = build(root, plugin, files, dirs, out)
        verify(out, plugin, names, want,
               m.get("FORBIDDEN_EXTRA", ""), str(m.get("ALLOW_SHELL_SCRIPTS", "")) == "1")

        print(f"built {out}")
        print(f"  plugin   : {plugin}")
        print(f"  version  : {read_version(root) or '<not found in metadata.txt>'}")
        print(f"  size     : {out.stat().st_size // 1024} KB")
        print("OK - one top-level folder, required entries present, "
              "no binaries/caches/archives/shell scripts.")
        return 0
    except BuildError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
