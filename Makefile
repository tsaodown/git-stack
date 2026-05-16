# git-stack — install / test targets.
#
# Override PREFIX to install elsewhere:   make install PREFIX=/usr/local
# Override JOBS to parallelize bats:      make test JOBS=8

PREFIX ?= $(HOME)/.local
BIN_DIR := $(PREFIX)/bin
JOBS    ?= 4

SCRIPT := bin/git-stack

.PHONY: install uninstall test help

help:
	@echo "targets:"
	@echo "  install     install $(SCRIPT) to $(BIN_DIR)/git-stack"
	@echo "  uninstall   remove $(BIN_DIR)/git-stack"
	@echo "  test        run bats tests (JOBS=$(JOBS))"

install: $(SCRIPT)
	install -d $(BIN_DIR)
	install -m 755 $(SCRIPT) $(BIN_DIR)/git-stack
	@echo "installed git-stack to $(BIN_DIR)/git-stack"

uninstall:
	rm -f $(BIN_DIR)/git-stack
	@echo "removed $(BIN_DIR)/git-stack"

test:
	bats --jobs $(JOBS) tests/
