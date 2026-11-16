# Quartermaster — the provisioning companion to Bosun.
#
# Two columns from one PureScript source: node (the development column and the
# conformance oracle) and the BEAM (purerl, beam/), which is what `make install`
# ships. Both need the `.#purerl` devshell's tools: spago, purs, node, and
# erl/erlc (OTP 27 or later). For example:
#
#   nix develop .#purerl --command make conformance
#
# Until 2026-11-16 the shipped column was a Gnomon (Go) binary; the Go backend
# is no longer an intended runtime, and its column is gone.

.PHONY: help build beam conformance menagerie install

help:
	@echo "Quartermaster targets:"
	@echo "  make build        spago build (PureScript)"
	@echo "  make beam         build the BEAM column (beam/ebin)"
	@echo "  make conformance  node CLI ≡ BEAM for EVERY verb (byte-diff)"
	@echo "  make menagerie    dual-runtime behavioural probe tests"
	@echo "  make install      install the BEAM build to \$$SHARE, launcher at \$$PREFIX/quartermaster"

build:
	spago build

beam:
	beam/build.sh

# The dual-runtime conformance gate: rebuilds both columns (a missing foreign
# twin fails the purerl build, and so the harness), then asserts node ≡ BEAM for
# verify, build, publish, apply, exec, brew and usage. Adding or changing a verb
# requires a conformance case in the script.
conformance:
	scripts/qm-conformance.sh

menagerie:
	scripts/qm-menagerie.sh

# The installed `quartermaster` is the BEAM build. `.beam` files are the same on
# every architecture, so this one directory runs on any host with OTP 27 or
# later (Nix's erlang_28 on substrate hosts): copy $(SHARE) and the launcher.
# The directory is replaced whole, and REVISION records the commit it was built
# from (with -dirty when the tree had uncommitted changes).
PREFIX ?= $(HOME)/.local/bin
SHARE ?= $(HOME)/.local/share/quartermaster
install: beam
	rm -rf "$(SHARE).new" && mkdir -p "$(SHARE).new/deps/yamerl"
	cp -R beam/ebin "$(SHARE).new/ebin"
	cp -R beam/deps/yamerl/ebin "$(SHARE).new/deps/yamerl/ebin"
	cp beam/quartermaster "$(SHARE).new/quartermaster"
	git describe --always --dirty > "$(SHARE).new/REVISION"
	rm -rf "$(SHARE)" && mv "$(SHARE).new" "$(SHARE)"
	mkdir -p "$(PREFIX)"
	rm -f "$(PREFIX)/quartermaster"
	printf '#!/bin/sh\nexec "%s/quartermaster" "$$@"\n' "$(SHARE)" > "$(PREFIX)/quartermaster"
	chmod +x "$(PREFIX)/quartermaster"
	@echo "installed $(SHARE) ($$(cat "$(SHARE)/REVISION")), launcher $(PREFIX)/quartermaster"
