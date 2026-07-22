#!/usr/bin/env bash
# build_plugin.sh - build a plugins.qgis.org-ready QGIS plugin zip from a manifest.
#
# Reads plugin_build.conf (see templates/plugin_build.conf), stages exactly the
# declared files and directories, strips caches and VCS dirs, zips with a single
# top-level folder, then SELF-VERIFIES the result: required entries present, no
# forbidden entries, no binaries, under the 20 MB repository limit.
#
#   Usage: scripts/build_plugin.sh [-c plugin_build.conf] [-o out.zip]
#
# Requires bash, zip and unzip. Git Bash on Windows ships none of the zip tools:
# use scripts/build_plugin.py there (same manifest, Python stdlib only).
#
# NOTE: the manifest is sourced by bash, so it executes with your privileges.
# It is a build file in your own repo, at the same trust level as a Makefile -
# but do not point -c at a manifest you did not write. build_plugin.py parses
# the same file without executing it if you need that guarantee.

set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

CONF=""
OUT_OVERRIDE=""
while getopts ":c:o:h" opt; do
  case "$opt" in
    c) CONF="$OPTARG" ;;
    o) OUT_OVERRIDE="$OPTARG" ;;
    h) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    \?) die "unknown option -$OPTARG (try -h)" ;;
    :) die "option -$OPTARG needs a value" ;;
  esac
done

# --- locate the manifest -----------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "$CONF" ]; then
  for cand in "$PWD/plugin_build.conf" "$SCRIPT_DIR/../plugin_build.conf"; do
    [ -f "$cand" ] && { CONF="$cand"; break; }
  done
fi
[ -n "$CONF" ] && [ -f "$CONF" ] || die "no plugin_build.conf found (looked in ./ and ../ of the script; pass -c PATH).
       Start from templates/plugin_build.conf in this skill."
CONF="$(cd "$(dirname "$CONF")" && pwd)/$(basename "$CONF")"
ROOT="$(dirname "$CONF")"

# --- load and validate -------------------------------------------------------
PLUGIN=""; FILES=(); DIRS=(); VERIFY=(); FORBIDDEN_EXTRA=""; OUT=""; ALLOW_SHELL_SCRIPTS=0
# shellcheck disable=SC1090
. "$CONF"

[ -n "$PLUGIN" ] || die "PLUGIN is not set in $CONF"
case "$PLUGIN" in
  *[!A-Za-z0-9_-]*) die "PLUGIN='$PLUGIN' must be a bare package name ([A-Za-z0-9_-] only) - it is the top folder in the zip and a Python import name" ;;
esac
[ "${#FILES[@]}" -gt 0 ] || die "FILES is empty in $CONF - list every module the plugin imports"

# Reject path escapes: everything must live under the manifest's directory.
check_rel() {
  case "$1" in
    /*|~*)  die "$2 entry '$1' must be relative to the manifest directory" ;;
    *..*)   die "$2 entry '$1' must not contain '..'" ;;
    "")     die "$2 contains an empty entry" ;;
  esac
}
for f in "${FILES[@]}"; do check_rel "$f" FILES; done
for d in ${DIRS[@]+"${DIRS[@]}"}; do check_rel "$d" DIRS; done

command -v zip   >/dev/null 2>&1 || die "'zip' not found. On Git Bash for Windows use scripts/build_plugin.py, or build from WSL / the OSGeo4W shell."
command -v unzip >/dev/null 2>&1 || die "'unzip' not found (needed for the self-verify step). See scripts/build_plugin.py."

[ -n "$OUT_OVERRIDE" ] && OUT="$OUT_OVERRIDE"
[ -n "$OUT" ] || OUT="$ROOT/$PLUGIN.zip"
case "$OUT" in /*) ;; *) OUT="$ROOT/$OUT" ;; esac
mkdir -p "$(dirname "$OUT")"

# --- stage -------------------------------------------------------------------
cd "$ROOT"
WORK="$(mktemp -d)"; STAGE="$WORK/$PLUGIN"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$STAGE"

for f in "${FILES[@]}"; do
  [ -f "$ROOT/$f" ] || die "FILES entry '$f' does not exist (relative to $ROOT)"
  mkdir -p "$STAGE/$(dirname "$f")"
  cp "$ROOT/$f" "$STAGE/$f"
done
for d in ${DIRS[@]+"${DIRS[@]}"}; do
  [ -d "$ROOT/$d" ] || die "DIRS entry '$d' does not exist (relative to $ROOT)"
  mkdir -p "$STAGE/$(dirname "$d")"
  cp -r "$ROOT/$d" "$STAGE/$d"
done

# --- strip what plugins.qgis.org rejects -------------------------------------
find "$STAGE" -type d \( -name '__pycache__' -o -name '.git' -o -name '.ruff_cache' \
     -o -name '.pytest_cache' -o -name '.mypy_cache' -o -name '__MACOSX' \) \
     -prune -exec rm -rf {} + 2>/dev/null || true
find "$STAGE" -type f \( -name '*.pyc' -o -name '*.pyo' -o -name '.DS_Store' \) -delete 2>/dev/null || true

# --- binary check (QGIS bans binaries in plugins) ----------------------------
BIN_HITS="$(find "$STAGE" -type f \( -name '*.exe' -o -name '*.dll' -o -name '*.so' \
            -o -name '*.dylib' -o -name '*.pyd' -o -name '*.a' -o -name '*.o' \
            -o -name '*.jar' -o -name '*.class' -o -name '*.bin' \) -print || true)"
[ -z "$BIN_HITS" ] || die "compiled binaries staged - plugins.qgis.org bans binaries:
$BIN_HITS"

# --- zip ---------------------------------------------------------------------
rm -f "$OUT"
( cd "$WORK" && zip -qr "$OUT" "$PLUGIN" )

# --- self-verify -------------------------------------------------------------
# Capture the listing ONCE into a variable. Piping `unzip -l` into `grep -q`
# makes grep exit on first match and close the pipe; unzip then dies with
# SIGPIPE (141) and `set -o pipefail` fails the line even though it matched.
LISTING="$(unzip -l "$OUT")"

TOPS="$(printf '%s\n' "$LISTING" | awk 'NF>=4 && $4 ~ /\// {split($4,a,"/"); print a[1]}' | sort -u)"
[ "$TOPS" = "$PLUGIN" ] || die "zip must contain exactly one top-level folder named '$PLUGIN', found: $(printf '%s' "$TOPS" | tr '\n' ' ')"

for want in ${VERIFY[@]+"${VERIFY[@]}"} LICENSE metadata.txt; do
  printf '%s\n' "$LISTING" | grep -q -- "$PLUGIN/$want" \
    || die "'$want' missing from the built zip - check FILES/DIRS in $CONF"
done

FORBIDDEN='__pycache__|\.git/|\.pyc|\.pyo|\.ruff_cache|__MACOSX|resources\.py|/docs/|\.tar\.gz|\.tgz|\.rar|\.7z'
if [ "${ALLOW_SHELL_SCRIPTS:-0}" != "1" ]; then
  FORBIDDEN="$FORBIDDEN|\\.sh$"
fi
[ -n "$FORBIDDEN_EXTRA" ] && FORBIDDEN="$FORBIDDEN|$FORBIDDEN_EXTRA"
HITS="$(printf '%s\n' "$LISTING" | grep -iE -- "$FORBIDDEN" || true)"
[ -z "$HITS" ] || die "forbidden entries in the zip (cache / VCS / generated / archive / shell script):
$HITS
       Shell scripts are flagged by the plugins.qgis.org security scanner. Put installer
       guidance in the README and link out with QDesktopServices.openUrl instead. If you
       have a reviewed reason to ship one, set ALLOW_SHELL_SCRIPTS=1 in the manifest."

SIZE_B="$(wc -c < "$OUT" | tr -d ' ')"
[ "$SIZE_B" -lt 20971520 ] || die "zip is $((SIZE_B/1048576)) MB - plugins.qgis.org limits packages to 20 MB"

VERSION="$(grep -E '^version=' "$STAGE/metadata.txt" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r' || true)"
note "built $OUT"
note "  plugin   : $PLUGIN"
note "  version  : ${VERSION:-<not found in metadata.txt>}"
note "  size     : $((SIZE_B/1024)) KB"
note "OK - one top-level folder, required entries present, no binaries/caches/archives/shell scripts."
