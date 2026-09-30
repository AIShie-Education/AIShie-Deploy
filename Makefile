# The checks CI runs, one target each, so that `make ci` here and a green
# pipeline mean the same thing. The end to end is apart: it sets the machine
# it runs on up as a server, as root, with the real images (tests/e2e.sh), so
# CI runs it on a runner it throws away.

SHELL       := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

# The POSIX sh scripts, which the server runs, and the tests', which are bash.
SH_SCRIPTS   := bin/aishie-update bin/aishie bin/aishie-storage setup-server.sh postgres/initdb/10-aishie.sh
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
# In a UTF-8 locale: shellcheck stops at the first « » it has to print in any
# other.
shellcheck: ## the scripts: POSIX sh for the server's, bash for the tests'
	LC_ALL=C.UTF-8 shellcheck -s sh $(SH_SCRIPTS)
	LC_ALL=C.UTF-8 shellcheck $(BASH_SCRIPTS)

.PHONY: actionlint
actionlint: ## the GitHub Actions workflows (and shellcheck over their run blocks)
	@if command -v actionlint >/dev/null; then actionlint; \
	else go run github.com/rhysd/actionlint/cmd/actionlint@$(ACTIONLINT_VERSION); fi

.PHONY: test
test: ## the scripts against stand-ins for docker, curl, flock and rclone
	@for t in tests/*_test.sh; do echo "== $$t"; $$t; done

.PHONY: config
config: ## docker compose config against the example settings, and caddy validate
	tests/config.sh

.PHONY: e2e
e2e: ## the whole stack for real: as root, on a machine that can be thrown away
	tests/e2e.sh
