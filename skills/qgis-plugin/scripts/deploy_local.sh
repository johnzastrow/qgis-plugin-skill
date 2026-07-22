#!/usr/bin/env bash
# deploy_local.sh - build the plugin and install it into a local QGIS profile.
#
#   Usage: scripts/deploy_local.sh [-c plugin_build.conf] [-p profile] [-q QGIS3|QGIS4] [-B]
#
#     -c  manifest path       (default: ./plugin_build.conf, then ../ of this script)
#     -p  QGIS profile name   (default: default)
#     -q  QGIS major version  (default: QGIS4)
#     -B  skip the build, install the existing zip
#
# The plugin name and output path come from the manifest, so there is nothing to
# edit per plugin. Falls back to build_plugin.py when the zip tools are absent
# (Git Bash on Windows).
#
# AFTER this runs, RESTART QGIS. A full restart is the only reliable reload;
# Plugin Reloader usually works. If you added the folder while QGIS was already
# running, refresh the import cache from the Python Console instead:
#   import importlib, qgis.utils as qu
#   importlib.invalidate_caches(); qu.updateAvailablePlugins()
#   qu.loadPlugin('<pkg>'); qu.startPlugin('<pkg>')      # or qu.reloadPlugin('<pkg>')
#
# NOTE: this copies the folder in directly, which is right for a fast edit/test
# loop but leaves the plugin NOT removable from the Plugin Manager. To test the
# real install path, use Plugins > Manage and Install > Install from ZIP, or
# pyplugin_installer.instance().installFromZipFile(zip).

set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

CONF=""; PROFILE="default"; QVER="QGIS4"; DO_BUILD=1
while getopts ":c:p:q:Bh" opt; do
  case "$opt" in
    c) CONF="$OPTARG" ;;
    p) PROFILE="$OPTARG" ;;
    q) QVER="$OPTARG" ;;
    B) DO_BUILD=0 ;;
    h) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    \?) die "unknown option -$OPTARG (try -h)" ;;
    :) die "option -$OPTARG needs a value" ;;
  esac
done

case "$QVER" in QGIS3|QGIS4) ;; *) die "-q must be QGIS3 or QGIS4 (got '$QVER')" ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "$CONF" ]; then
  for cand in "$PWD/plugin_build.conf" "$SCRIPT_DIR/../plugin_build.conf"; do
    [ -f "$cand" ] && { CONF="$cand"; break; }
  done
fi
[ -n "$CONF" ] && [ -f "$CONF" ] || die "no plugin_build.conf found (pass -c PATH)"
CONF="$(cd "$(dirname "$CONF")" && pwd)/$(basename "$CONF")"
ROOT="$(dirname "$CONF")"

PLUGIN=""; OUT=""
# shellcheck disable=SC1090
. "$CONF"
[ -n "$PLUGIN" ] || die "PLUGIN is not set in $CONF"
[ -n "$OUT" ] || OUT="$ROOT/$PLUGIN.zip"
case "$OUT" in /*) ;; *) OUT="$ROOT/$OUT" ;; esac

# --- QGIS profile location ---------------------------------------------------
case "$(uname -s)" in
  Linux)
    PLUGINS="$HOME/.local/share/QGIS/$QVER/profiles/$PROFILE/python/plugins" ;;
  Darwin)
    PLUGINS="$HOME/Library/Application Support/QGIS/$QVER/profiles/$PROFILE/python/plugins" ;;
  MINGW*|MSYS*|CYGWIN*)
    [ -n "${APPDATA:-}" ] || die "APPDATA is not set; cannot locate the QGIS profile"
    PLUGINS="$(printf '%s' "$APPDATA" | tr '\\' '/')/QGIS/$QVER/profiles/$PROFILE/python/plugins" ;;
  *)
    die "unsupported OS $(uname -s). Install manually into <QGIS profile>/python/plugins/$PLUGIN/" ;;
esac

# --- build -------------------------------------------------------------------
if [ "$DO_BUILD" -eq 1 ]; then
  if command -v zip >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
    bash "$SCRIPT_DIR/build_plugin.sh" -c "$CONF"
  else
    echo "note: zip/unzip not available, building with build_plugin.py"
    python3 "$SCRIPT_DIR/build_plugin.py" -c "$CONF" 2>/dev/null \
      || python "$SCRIPT_DIR/build_plugin.py" -c "$CONF"
  fi
fi
[ -f "$OUT" ] || die "zip not found at $OUT (build it first, or drop -B)"

# --- install -----------------------------------------------------------------
mkdir -p "$PLUGINS"
rm -rf "${PLUGINS:?}/$PLUGIN"
if command -v unzip >/dev/null 2>&1; then
  unzip -q "$OUT" -d "$PLUGINS"
else
  (python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$OUT" "$PLUGINS" 2>/dev/null \
    || python -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$OUT" "$PLUGINS")
fi

echo "installed $PLUGIN -> $PLUGINS/$PLUGIN"
echo "RESTART QGIS to load it."
