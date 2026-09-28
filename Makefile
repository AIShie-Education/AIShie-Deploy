# The checks CI runs, one target each, so that `make ci` here and a green
# pipeline mean the same thing. The end to end is CI's alone: it needs the
# real images and a Docker that can run them (tests/e2e.sh).

SHELL       := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

# The POSIX sh scripts, which the server runs, and the tests', which are bash.
SH_SCRIPTS   := bin/aishie-update bin/aishie setup-server.sh postgres/initdb/10-aishie.sh
BASH_SCRIPTS := $(wildcard tests/*.sh)

ACTIONLINT_VERSION ?= v1.7.12
CADDY_IMAGE        ?= caddy:2

.PHONY: help
help:
	@grep -E '^[a-z][a-z0-9-]*:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

.PHONY: ci
ci: lint test config ## everything CI checks but the end to end

.PHONY: lint
lint: shellcheck actionlint ## shellcheck and actionlint

.PHONY: shellcheck
shellcheck: ## the scripts: POSIX sh for the server's, bash for the tests'
	shellcheck -s sh $(SH_SCRIPTS)
	shellcheck $(BASH_SCRIPTS)

.PHONY: actionlint
actionlint: ## the GitHub Actions workflows (and shellcheck over their run blocks)
	@if command -v actionlint >/dev/null; then actionlint; \
	else go run github.com/rhysd/actionlint/cmd/actionlint@$(ACTIONLINT_VERSION); fi

.PHONY: test
test: ## the scripts against stand-ins for docker, curl and flock
	@for t in tests/*_test.sh; do echo "== $$t"; $$t; done

.PHONY: config
config: ## docker compose config against the example settings, and caddy validate
	tests/config.sh
