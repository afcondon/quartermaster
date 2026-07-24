# Quartermaster — the provisioning companion to Bosun.
#
# Note on toolchains: the PureScript build lives in the `.#purescript` nix
# devshell and the Go (Gnomon backend-go) build in `.#go`. `make conformance`
# rebuilds the native Gnomon binary as its first step, so it needs BOTH `spago`
# and `go` on PATH. From a `.#purescript` shell, prepend the `.#go` bin, e.g.:
#
#   nix develop .#purescript --command bash -c '
#     export PATH="$(nix develop .#go --command dirname "$(which go)"):$PATH"
#     make conformance'

.PHONY: help build conformance menagerie

help:
	@echo "Quartermaster targets:"
	@echo "  make build        spago build (PureScript)"
	@echo "  make conformance  node CLI ≡ Gnomon (backend-go) for EVERY verb (byte-diff)"
	@echo "  make menagerie    dual-runtime behavioural probe tests"

build:
	spago build

# The dual-runtime conformance gate: rebuilds the Gnomon binary (a broken Go
# build — e.g. a missing FFI twin — fails the harness under `set -euo pipefail`),
# then asserts node ≡ gnomon for verify, build, publish, apply, exec, and usage.
# Adding or changing a verb requires a conformance case in the script.
conformance:
	scripts/qm-conformance.sh

menagerie:
	scripts/qm-menagerie.sh
