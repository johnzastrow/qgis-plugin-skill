# Makefile - identical across every QGIS plugin repo.
#
# Everything plugin-specific lives in plugin_build.conf; only UNIT_TEST below
# may need changing. Copy this to your plugin repo root alongside
# plugin_build.conf and scripts/.
#
#   make check     lint + security gates + unit tests (run before every release)
#   make build     self-verifying plugin zip
#   make deploy    build + install into the local QGIS profile
#   make tag V=x.y.z   verify the version is bumped everywhere, then tag and push
#
# Requires `uv` (https://docs.astral.sh/uv/) so the linters run in throwaway
# environments with nothing installed globally.

UNIT_TEST ?= test
EXCLUDE   ?= .git,test,tests,help,i18n,__pycache__,docs,resources.py
BANDIT_X  ?= ./test,./tests,./.git,./help,./docs

.DEFAULT_GOAL := check
.PHONY: check lint style security leak-scan test build deploy tag clean

check: lint style security leak-scan test
	@echo "all gates passed"

# ruff is fast and fixes; flake8 is the authoritative gate (see below).
# Pin ruff to the same version as release.yml (RUFF_VERSION) and run the same two commands,
# so a local pass means a CI pass. An unpinned local ruff, or a missing format check, lets a
# formatting change (including Python code blocks in Markdown) through to a red CI.
RUFF_VERSION ?= 0.15.19
lint:
	uv run --no-project --with "ruff==$(RUFF_VERSION)" ruff check .
	uv run --no-project --with "ruff==$(RUFF_VERSION)" ruff format --check .

# flake8 is what plugins.qgis.org runs. ruff does not implement the pycodestyle
# continuation-indent checks (E12x) or W503/W504, so a clean ruff is NOT proof.
style:
	uv run --no-project --with flake8 flake8 .

# HIGH/critical findings are a hard block on upload.
security:
	uv run --no-project --with bandit bandit -r . -x $(BANDIT_X)

# Secrets scan. Named leak-scan, NOT "secrets": detect-secrets reads a `secrets:`
# make target as a secret keyword and flags the recipe lines under it, so a
# target with that name makes the scan fail on this very Makefile.
# Delete caches first: .ruff_cache/CACHEDIR.TAG trips a false "high entropy string".
# `detect-secrets scan` exits 0 even when it finds something, so the JSON result
# is checked here and any finding fails the gate.
leak-scan:
	rm -rf .ruff_cache .pytest_cache
	uv run --no-project --with detect-secrets detect-secrets scan --all-files --exclude-files '^\.git/' \
	  | python3 -c "import json,sys; r=json.load(sys.stdin)['results']; print(json.dumps(r, indent=2) if r else 'no findings'); sys.exit(1 if r else 0)"

test:
	python -m pytest $(UNIT_TEST) -q || python -m unittest discover -s $(UNIT_TEST) -v

build:
	bash scripts/build_plugin.sh

deploy:
	bash scripts/deploy_local.sh

# Refuses to tag if the version is not bumped consistently.
tag:
	@test -n "$(V)" || { echo "usage: make tag V=x.y.z"; exit 1; }
	@grep -q "^version=$(V)$$" metadata.txt \
	  || { echo "metadata.txt version= is not $(V)"; exit 1; }
	@grep -q "$(V)" CHANGELOG.md docs/CHANGELOG.md 2>/dev/null \
	  || { echo "no CHANGELOG entry for $(V)"; exit 1; }
	@! grep -rn "__version__" --include="*.py" . | grep -v "$(V)" \
	  || { echo "a source __version__ disagrees with $(V)"; exit 1; }
	$(MAKE) check build
	git tag -a v$(V) -m "v$(V)" && git push origin v$(V)

clean:
	rm -rf .ruff_cache .pytest_cache
	find . -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
