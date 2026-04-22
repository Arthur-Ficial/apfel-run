.PHONY: build test release install uninstall clean version

VERSION := $(shell cat .version)
PREFIX := /usr/local

build:
	swift build -c release

test:
	swift test

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
