# Makefile — Bash WP-CLI Update
#
# The artifacts at the repository root are generated from src/ by tools/build.sh.
# `make check` is what CI runs and what a PR must pass.

SHELL      := /bin/bash
PREFIX     ?= /opt/wp-cli-update
CONFDIR    ?= /etc
DATADIR    ?= /var/lib/wp-cli-update
LOGDIR     ?= /var/log/wp-cli-update
BACKUPDIR  ?= /var/backups/wp-cli-update
COMPLDIR   ?= /usr/share/bash-completion/completions
BUILD_ID   ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)

MANAGER    := Bash_WP-CLI_Update.sh
FINDER     := Find_WP_Senior.sh
SOURCES    := $(wildcard src/manager/*.sh) $(wildcard src/finder/*.sh) tools/build.sh

.PHONY: all build check lint test secrets install uninstall clean help

all: build

## build: regenerate both single-file artifacts from src/
build: $(SOURCES)
	WPU_BUILD_ID="$(BUILD_ID)" WPU_SYNTAX_FORK=1 bash tools/build.sh

## check: build, prove the artifacts match src/, lint, scan for secrets, run the suites
check: build drift lint secrets test

## drift: fail when the committed artifacts do not match src/
drift:
	WPU_BUILD_ID="$(BUILD_ID)" bash tools/build.sh --check

## lint: shellcheck over artifacts, tools and tests (skips gracefully when absent)
lint:
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck not installed - skipped"; exit 0; }
	shellcheck -x $(MANAGER) $(FINDER) tools/build.sh tools/scan-secrets.sh tools/install.sh
	@for f in src/manager/*.sh src/finder/*.sh tests/*.sh tests/stub/wp; do \
	    shellcheck -e SC2154 -e SC2034 -e SC2329 -x "$$f" || exit 1; \
	done

## test: the nine suites; no root, no WordPress, no WP-CLI, no network
test:
	bash tests/run_tests.sh

## secrets: scan the work tree (and history when git is present)
secrets:
	bash tools/scan-secrets.sh --strict

## install: scripts + completion + directories + a starter config (does not overwrite an existing one)
install: build
	install -d "$(DESTDIR)$(PREFIX)" "$(DESTDIR)$(DATADIR)" "$(DESTDIR)$(LOGDIR)" \
	        "$(DESTDIR)$(BACKUPDIR)" "$(DESTDIR)$(DATADIR)/prometheus"
	install -m 755 $(MANAGER) $(FINDER) "$(DESTDIR)$(PREFIX)/"
	install -m 755 tools/scan-secrets.sh "$(DESTDIR)$(PREFIX)/tools/" 2>/dev/null || \
	    { install -d "$(DESTDIR)$(PREFIX)/tools" && install -m 755 tools/scan-secrets.sh "$(DESTDIR)$(PREFIX)/tools/"; }
	install -m 644 tools/secret-allowlist.txt "$(DESTDIR)$(PREFIX)/tools/"
	if [ -d "$(DESTDIR)$(COMPLDIR)" ] || [ -z "$(DESTDIR)" ]; then \
	    install -d "$(DESTDIR)$(COMPLDIR)" 2>/dev/null && \
	    "$(DESTDIR)$(PREFIX)/$(MANAGER)" --completion bash > "$(DESTDIR)$(COMPLDIR)/wp-fleet" 2>/dev/null || true; \
	fi
	if [ ! -e "$(DESTDIR)$(CONFDIR)/wp-cli-update.conf" ]; then \
	    "$(DESTDIR)$(PREFIX)/$(MANAGER)" --init-config "$(DESTDIR)$(CONFDIR)/wp-cli-update.conf" 2>/dev/null || \
	    install -m 600 wp-cli-update.conf.example "$(DESTDIR)$(CONFDIR)/wp-cli-update.conf"; \
	fi
	@echo
	@echo "Installed into $(DESTDIR)$(PREFIX)"
	@echo "  config   : $(DESTDIR)$(CONFDIR)/wp-cli-update.conf"
	@echo "  sites    : $(DESTDIR)$(DATADIR)/wp-found.txt"
	@echo "  logs     : $(DESTDIR)$(LOGDIR)"
	@echo "  backups  : $(DESTDIR)$(BACKUPDIR)"
	@echo "Next: $(DESTDIR)$(PREFIX)/$(MANAGER) --wpcli-check && $(DESTDIR)$(PREFIX)/$(MANAGER) --check"

## uninstall: remove the installed files (leaves logs, backups and state)
uninstall:
	rm -f "$(DESTDIR)$(PREFIX)/$(MANAGER)" "$(DESTDIR)$(PREFIX)/$(FINDER)"
	rm -rf "$(DESTDIR)$(PREFIX)/tools"
	rm -f "$(DESTDIR)$(COMPLDIR)/wp-fleet"

## clean: remove editor droppings; artifacts are committed, so they stay
clean:
	find . -name '*~' -delete 2>/dev/null || true

## help: list the targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
