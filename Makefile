# Bash WP-CLI Update — development entry points.
#
# The product is one shell script; everything here is about proving it works.
# `make test` needs no root, no WordPress, no WP-CLI and no network.

PREFIX      ?= /usr/local
DESTDIR     ?=
VERSION     := $(shell sed -n "s/^SCRIPT_VERSION='\(.*\)'.*/\1/p" Bash_WP-CLI_Update.sh | head -1)
SHELLCHECK  ?= shellcheck
SHELLS      := Bash_WP-CLI_Update.sh Find_WP_Senior.sh tools/scan-secrets.sh

.PHONY: help test test-v7 lint syntax dist install uninstall shellcheck-version

help:
	@echo "make test        run every test suite (no root, no network)"
	@echo "make test-v7     run only the 7.0.0 feature suite"
	@echo "make lint        bash -n plus shellcheck on every shell file"
	@echo "make dist        build dist/bash-wp-cli-update-$(VERSION).tar.gz"
	@echo "make install     copy the product into $(DESTDIR)$(PREFIX) (root)"
	@echo "make uninstall   remove the two symlinks (keeps configuration and logs)"
	@echo "version          $(VERSION)"

test:
	@bash tests/run_tests.sh

test-v7:
	@bash tests/run_tests.sh v7

syntax:
	@for f in $(SHELLS) tests/*.sh tests/stub/wp; do bash -n "$$f" || exit 1; done
	@echo "syntax: ok"

shellcheck-version:
	@$(SHELLCHECK) --version | head -2

lint: syntax
	@command -v $(SHELLCHECK) >/dev/null || { echo "shellcheck is not installed"; exit 1; }
	@$(SHELLCHECK) -f gcc $(SHELLS) tests/*.sh tests/stub/wp
	@echo "lint: ok"

# What ships. The frozen 6.3/6.4 snapshots, the test bench and the working
# directories are deliberately excluded: the archive is the product, not the lab.
dist: lint test
	@mkdir -p dist
	@tar czf dist/bash-wp-cli-update-$(VERSION).tar.gz \
		--exclude=dist --exclude=.git --exclude=.ragraf --exclude=.zwork \
		--exclude=.compare --exclude=6.3 --exclude=6.4 --exclude=research \
		--exclude=stand --exclude=bin --exclude=backups --exclude='*.log' \
		Bash_WP-CLI_Update.sh Find_WP_Senior.sh wp-cli-update.conf.example \
		README.md AGENTS.md AGENT.md CHANGELOG.md PROJECT_MAP.md SECURITY.md LICENSE \
		docs contrib tools tests .gitignore .gitattributes Makefile
	@echo "dist/bash-wp-cli-update-$(VERSION).tar.gz"

install:
	@test "$$(id -u)" = "0" || { echo "install needs root"; exit 1; }
	install -d -m 755 $(DESTDIR)$(PREFIX)/lib/wp-cli-update
	install -m 755 Bash_WP-CLI_Update.sh $(DESTDIR)$(PREFIX)/lib/wp-cli-update/
	install -m 755 Find_WP_Senior.sh     $(DESTDIR)$(PREFIX)/lib/wp-cli-update/
	install -m 644 wp-cli-update.conf.example $(DESTDIR)$(PREFIX)/lib/wp-cli-update/
	ln -sf $(PREFIX)/lib/wp-cli-update/Bash_WP-CLI_Update.sh $(DESTDIR)$(PREFIX)/bin/wp-cli-update
	ln -sf $(PREFIX)/lib/wp-cli-update/Find_WP_Senior.sh     $(DESTDIR)$(PREFIX)/bin/wp-find
	install -d -m 755 /var/log/wp-cli-update /var/backups/wp-cli-update /var/lib/wp-cli-update
	@echo "installed; next: install -m 600 wp-cli-update.conf.example /etc/wp-cli-update.conf"

uninstall:
	@test "$$(id -u)" = "0" || { echo "uninstall needs root"; exit 1; }
	rm -f $(DESTDIR)$(PREFIX)/bin/wp-cli-update $(DESTDIR)$(PREFIX)/bin/wp-find
	@echo "symlinks removed; $(PREFIX)/lib/wp-cli-update, /etc/wp-cli-update.conf, logs and backups were kept"
