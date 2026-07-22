#!/usr/bin/env bash
# smoke_build.sh - regression guard for the build tooling shipped in this skill.
#
# Builds a synthetic QGIS plugin with both builders and asserts they agree, then
# walks the failure modes and asserts each one is REJECTED. The point of the
# build scripts is that they refuse to ship a bad zip, so the failure cases are
# the part that actually matters.
#
#   Usage: tests/smoke_build.sh
#   Exit:  0 all good, 1 something regressed
#
# Runs anywhere with bash + zip + unzip + python3. No network, no QGIS needed.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$ROOT/skills/qgis-plugin/scripts"
PASS=0
FAIL=0

ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FIX="$WORK/fixture"
mkdir -p "$FIX/db" "$FIX/widgets" "$FIX/icons"

cat > "$FIX/metadata.txt" <<'EOF'
[general]
name=Fixture Plugin
qgisMinimumVersion=3.40
qgisMaximumVersion=4.99
version=1.2.3
author=Test
email=test@users.noreply.github.com
EOF
printf 'def classFactory(iface):\n    from .fixture import Plugin\n    return Plugin(iface)\n' > "$FIX/__init__.py"
printf 'class Plugin:\n    pass\n' > "$FIX/fixture.py"
printf '# db\n'      > "$FIX/db/__init__.py"
printf '# widgets\n' > "$FIX/widgets/__init__.py"
printf '<svg/>\n'    > "$FIX/icons/icon.svg"
cp "$FIX/icons/icon.svg" "$FIX/icon.svg"
echo MIT > "$FIX/LICENSE"
# Deliberate junk that MUST be stripped, and hazards that MUST be rejected.
mkdir -p "$FIX/db/__pycache__" && echo junk > "$FIX/db/__pycache__/stale.pyc"
printf '#!/bin/sh\nwget http://example.invalid/tool && sudo mv tool /usr/local/bin/\n' > "$FIX/install_tool.sh"
head -c 64 /dev/urandom > "$FIX/db/native.so"

conf() { printf '%s\n' "$1" > "$FIX/plugin_build.conf"; }

GOOD='PLUGIN="FixturePlugin"
FILES=(__init__.py fixture.py metadata.txt icon.svg LICENSE)
DIRS=(icons widgets)
VERIFY=(icons/ widgets/ LICENSE metadata.txt)'

echo "== happy path =="
conf "$GOOD"
if out=$(bash "$SCRIPTS/build_plugin.sh" -c "$FIX/plugin_build.conf" -o "$WORK/sh.zip" 2>&1); then
  ok "build_plugin.sh builds"
else
  bad "build_plugin.sh builds" "$(echo "$out" | head -2)"
fi
if out=$(python3 "$SCRIPTS/build_plugin.py" -c "$FIX/plugin_build.conf" -o "$WORK/py.zip" 2>&1); then
  ok "build_plugin.py builds"
else
  bad "build_plugin.py builds" "$(echo "$out" | head -2)"
fi

if [ -f "$WORK/sh.zip" ] && [ -f "$WORK/py.zip" ]; then
  a=$(unzip -Z1 "$WORK/sh.zip" | grep -v '/$' | sort)
  b=$(unzip -Z1 "$WORK/py.zip" | grep -v '/$' | sort)
  [ "$a" = "$b" ] && ok "both builders emit identical file sets" \
                  || bad "both builders emit identical file sets" "$(diff <(echo "$a") <(echo "$b") | head -4)"
  unzip -Z1 "$WORK/sh.zip" | grep -qiE '__pycache__|\.pyc' \
    && bad "caches stripped from the zip" || ok "caches stripped from the zip"
  tops=$(unzip -Z1 "$WORK/sh.zip" | cut -d/ -f1 | sort -u | tr -d '\n')
  [ "$tops" = "FixturePlugin" ] && ok "exactly one top-level folder" \
                                || bad "exactly one top-level folder" "got: $tops"
fi

echo "== failure modes (each MUST be rejected) =="
reject() { # name, conf
  conf "$2"
  bash "$SCRIPTS/build_plugin.sh" -c "$FIX/plugin_build.conf" -o "$WORK/x.zip" >/dev/null 2>&1
  local rsh=$?
  python3 "$SCRIPTS/build_plugin.py" -c "$FIX/plugin_build.conf" -o "$WORK/y.zip" >/dev/null 2>&1
  local rpy=$?
  if [ "$rsh" -ne 0 ] && [ "$rpy" -ne 0 ]; then
    ok "$1"
  else
    bad "$1" "sh exit=$rsh py exit=$rpy (0 means it wrongly succeeded)"
  fi
}

reject "shell script in the zip" 'PLUGIN="P"
FILES=(__init__.py metadata.txt LICENSE install_tool.sh)
VERIFY=(LICENSE)'
reject "compiled binary in a shipped dir" 'PLUGIN="P"
FILES=(__init__.py metadata.txt LICENSE)
DIRS=(db)
VERIFY=(LICENSE)'
reject "path traversal in FILES" 'PLUGIN="P"
FILES=(__init__.py metadata.txt LICENSE ../../../etc/passwd)
VERIFY=(LICENSE)'
reject "unsafe PLUGIN name" 'PLUGIN="../evil"
FILES=(__init__.py metadata.txt LICENSE)
VERIFY=(LICENSE)'
reject "VERIFY entry not actually shipped" 'PLUGIN="P"
FILES=(__init__.py metadata.txt LICENSE)
VERIFY=(widgets/ LICENSE)'
reject "LICENSE omitted" 'PLUGIN="P"
FILES=(__init__.py metadata.txt)
VERIFY=()'
reject "nonexistent FILES entry" 'PLUGIN="P"
FILES=(__init__.py metadata.txt LICENSE ghost.py)
VERIFY=(LICENSE)'

echo "== documented override still works =="
conf 'PLUGIN="P"
FILES=(__init__.py metadata.txt LICENSE install_tool.sh)
VERIFY=(LICENSE)
ALLOW_SHELL_SCRIPTS=1'
bash "$SCRIPTS/build_plugin.sh" -c "$FIX/plugin_build.conf" -o "$WORK/allow.zip" >/dev/null 2>&1
rsh=$?
python3 "$SCRIPTS/build_plugin.py" -c "$FIX/plugin_build.conf" -o "$WORK/allowpy.zip" >/dev/null 2>&1
rpy=$?
{ [ "$rsh" -eq 0 ] && [ "$rpy" -eq 0 ]; } \
  && ok "ALLOW_SHELL_SCRIPTS=1 permits a reviewed *.sh" \
  || bad "ALLOW_SHELL_SCRIPTS=1 permits a reviewed *.sh" "sh exit=$rsh py exit=$rpy"

echo "== missing manifest gives a clear error =="
iso="$WORK/iso"; mkdir -p "$iso"
( cd "$iso" && bash "$SCRIPTS/build_plugin.sh" -c "$iso/nope.conf" >/dev/null 2>&1 )
[ $? -ne 0 ] && ok "missing manifest is an error" || bad "missing manifest is an error"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
