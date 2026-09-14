# Reliability Lab: the single entry point.
#
# Every action, on a laptop or in CI, is a target here. Workflows call these
# targets and nothing else, so `make pr` on a laptop reproduces the pull
# request check. Run `make help` for the list.

SHELL := bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help
.DELETE_ON_ERROR:
MAKEFLAGS += --warn-undefined-variables --no-builtin-rules --no-print-directory

# Put the tools pinned in .mise.toml first on PATH, so make works without
# activating mise in your shell. In CI, mise-action has already done the same.
export PATH := $(shell mise bin-paths 2>/dev/null | tr '\n' ':')$(PATH)

# uv must use the Python that mise installed, never download its own.
export UV_PYTHON_DOWNLOADS := never

# Python commands run from tools/, where the uv workspace and its settings
# live. --locked fails when uv.lock is out of date instead of re-resolving.
PY := cd tools && uv run --locked

# Files that belong to the repository: tracked ones, plus new ones that aren't
# ignored. Linters look only at these, never at ignored or local-only files.
# A tracked file deleted from the working tree stays in the index until the
# deletion is staged; it has nothing left to lint, so it is skipped.
repo_files = git ls-files --cached --others --exclude-standard -- $(1) | \
	while read -r f; do if [ -e "$$f" ]; then echo "$$f"; fi; done

# Run command $(3) on the repository files matching $(2), or say there are
# none. $(1) labels the message.
on_files = files=$$($(call repo_files,$(2))); \
	if [ -z "$$files" ]; then echo "$(1): no files to check"; else $(3) $$files; fi

##@ Getting started

.PHONY: help
help: ## Show this help
	@awk 'BEGIN { FS = ":.*## " } \
		/^##@/ { printf "\n%s\n", substr($$0, 5) } \
		/^[a-z][a-z-]*:.*## / { printf "  %-10s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo

.PHONY: tools
tools: ## Install the pinned tools and the Python environment
	@command -v mise >/dev/null || { echo "Install mise first: https://mise.jdx.dev" >&2; exit 1; }
	mise install
	# The PATH above was computed before this install, so go through mise.
	cd tools && mise exec -- uv sync --locked

# Targets that run pinned tools depend on this check. Without it, a fresh
# clone fails halfway through with "command not found": mise won't read a
# .mise.toml it hasn't been told to trust, and the PATH line above hides why.
# `make tools` fixes both cases, because `mise install` trusts the config it
# installs from.
.PHONY: require-tools
require-tools:
	@command -v mise >/dev/null || { echo "Install mise first: https://mise.jdx.dev" >&2; exit 1; }
	@missing=$$(mise ls --current --missing 2>/dev/null) || \
		{ echo "mise can't read .mise.toml yet. Run 'make tools' first." >&2; exit 1; }; \
	if [ -n "$$missing" ]; then \
		echo "Pinned tools are missing. Run 'make tools' first. Missing:" >&2; \
		echo "$$missing" | awk '{ print "  " $$1 " " $$2 }' >&2; \
		exit 1; \
	fi

##@ Checks (each linter also runs alone, for example `make lint-go`)

.PHONY: lint lint-yaml lint-markdown lint-links lint-shell lint-workflows lint-editorconfig lint-go lint-python
lint: lint-yaml lint-markdown lint-links lint-shell lint-workflows lint-editorconfig lint-go lint-python ## Run every linter

lint-yaml:
	@$(call on_files,yamllint,'*.yml' '*.yaml',uv run --project tools --locked yamllint --strict)

lint-markdown:
	@$(call on_files,rumdl,'*.md',rumdl check)

# Relative links and heading anchors only; --offline never touches the network.
lint-links:
	@$(call on_files,lychee,'*.md',lychee --offline --include-fragments --no-progress)

lint-shell:
	@$(call on_files,shellcheck,'*.sh',shellcheck)

lint-workflows:
	actionlint
	zizmor --offline .github/workflows

lint-editorconfig:
	@$(call on_files,editorconfig-checker,,editorconfig-checker)

lint-go:
	@unformatted=$$(cd app && gofmt -l .); \
		if [ -n "$$unformatted" ]; then echo "gofmt: run 'gofmt -w' on:"; echo "$$unformatted"; exit 1; fi
	cd app && go vet ./...
	cd app && golangci-lint run ./...

lint-python:
	$(PY) ruff check .
	$(PY) ruff format --check .
	$(PY) mypy

.PHONY: test test-go test-python test-workflows
test: test-go test-python test-workflows ## Run every test and repository check

test-go:
	cd app && go test -race ./...

test-python:
	$(PY) pytest

# Workflows may only call make targets: that is what keeps `make pr` honest.
test-workflows:
	$(PY) repo-checks workflows ../.github/workflows

# Each check needs the pinned tools, whether it runs alone or as part of
# `make lint`. Make runs require-tools once per invocation, not once per check.
lint-yaml lint-markdown lint-links lint-shell lint-workflows lint-editorconfig \
	lint-go lint-python test-go test-python test-workflows: | require-tools

.PHONY: pr
pr: lint test ## Run exactly what the pull request check runs

##@ Lab

.PHONY: down
down: ## Delete the cluster; safe to run at any time
	@echo "down: nothing to delete yet"

up: ## Create the cluster, install the platform and deploy the app
smoke: ## Check every user journey through the gateway
images: ## Build the service images and push them to the registry
budget: ## Record setup time and resource use

##@ Game day

baseline: ## Run baseline load and check every SLO
plan: ## Write plan.json: the experiment groups to run
gameday: ## Run experiments on the current cluster (GROUP=, EXP=, VARIANT=)
report: ## Build the results file, report and trends from evidence
status: ## Write the run summary; exit non-zero on red or yellow
nightly: ## Run every nightly stage in order, like the nightly workflow

##@ Site and history

publish: ## Add the run to history and build the site
issues: ## Open, update or close failure issues (a dry run outside CI)
history: ## Seed history/ from the published data branch
site: ## Build the site from history
serve: ## Serve the built site on localhost

# Targets that are planned but not built yet fail loudly, so nothing can
# quietly depend on them.
NOT_BUILT_YET := up smoke images budget baseline plan gameday report status nightly publish issues history site serve
.PHONY: $(NOT_BUILT_YET)
$(NOT_BUILT_YET):
	@echo "make $@: not implemented yet" >&2
	@exit 1
