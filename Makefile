.PHONY: build test smoke-auth release install uninstall clean version

VERSION := $(shell cat .version)
PREFIX := /usr/local

build:
	swift build -c release

test:
	swift test

# OAuth loopback smoke test against a local fake AS (scripts/auth-loopback-smoke.sh).
# Separate from `make test` because it touches the real user Keychain
# (creates and removes one item) and needs the release binary.
smoke-auth: build
	bash scripts/auth-loopback-smoke.sh

version:
	@echo $(VERSION)

install: build
	install -d $(PREFIX)/bin
	install -m 0755 .build/release/apfel-run $(PREFIX)/bin/apfel-run
	@echo "installed: $(PREFIX)/bin/apfel-run ($(VERSION))"

uninstall:
	rm -f $(PREFIX)/bin/apfel-run

clean:
	swift package clean
	rm -rf .build

release: test
	@echo "Release workflow lives in scripts/ once we wire homebrew-tap - not implemented yet"
