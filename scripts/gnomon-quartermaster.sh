#!/usr/bin/env bash
# gnomon-quartermaster — the Gnomon (backend-go) build of the REAL `quartermaster`
# CLI. The exact parallel of bosun/scripts/gnomon-bosun.sh.
#
# AC (2026-06-19): "use the gnomon version all the time to stress test the
# backend." So this transpiles the actual `Quartermaster.CLI.Main` to a NATIVE Go
# binary (via backend-go) and runs it with your args — every invocation exercises
# backend-go on real files. The binary is CACHED at $BIN and rebuilt only when a
# .purs or app-foreign .go is newer (so day-to-day use is just a native exec).
#
# It is Node-free: reads real compose.yml via gopkg.in/yaml.v3 (the go-apply-cli
# pattern — a one-line go.mod makes the generated `package main` a module that can
# import yaml; backend-go output stays dep-free, only Quartermaster's IO foreign
# imports it), and runs probes via /bin/sh exactly like the node Probe.js edge
# (so remote ssh-wrapped, envPrefix-aware verify works identically).
#
# Covers BOTH verbs Node-free:  verify <compose> <registry>
#                               build [--registry R] [--pin P] <compose> <registry>
#
# Shared library foreigns (argonaut / foreign-object) come from the SIBLING Bosun
# repo's conformance/go — Quartermaster already hard-depends on ../bosun via spago
# path-imports, so reusing its decode twins (rather than duplicating them) keeps
# one source of truth until the per-backend runtime-libraries repo exists.
#
# Usage:  scripts/gnomon-quartermaster.sh <verb> [args…]   (same args as node CLI)
#   e.g.  scripts/gnomon-quartermaster.sh verify fixtures/menagerie/compose.yml fixtures/menagerie/registry.json
#         BACKEND_GO=/path scripts/gnomon-quartermaster.sh build <compose> <registry>
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QM="$(cd "$HERE/.." && pwd)"
BOSUN="$(cd "$QM/../bosun" && pwd)"
BACKEND_GO="${BACKEND_GO:-$QM/../../purescript-backends/purescript-go/backend-go}"
MAIN="Quartermaster.CLI.Main"
OUT="${OUT:-/tmp/quartermaster-gnomon-cli}"
BIN="${BIN:-/tmp/gnomon-quartermaster}"
YAML_VERSION="${YAML_VERSION:-v3.0.1}"

log(){ echo "gnomon-quartermaster: $*" >&2; }   # build chatter to stderr; stdout stays the binary's

stale(){
  [ ! -x "$BIN" ] && return 0
  [ -n "$(find "$QM/cli" "$QM/core" -name '*.purs' -newer "$BIN" -print -quit 2>/dev/null)" ] && return 0
  [ -n "$(find "$QM/cli/go" -name '*.go' -newer "$BIN" -print -quit 2>/dev/null)" ] && return 0
  # shared bosun-core/adapters sources (path-imported) also affect the build
  [ -n "$(find "$BOSUN/core" "$BOSUN/adapters" -name '*.purs' -newer "$BIN" -print -quit 2>/dev/null)" ] && return 0
  [ -n "$(find "$BOSUN/conformance/go" -maxdepth 1 \( -name 'argonaut_*.go' -o -name 'foreign_object_*.go' \) -newer "$BIN" -print -quit 2>/dev/null)" ] && return 0
  return 1
}

build(){
  [ -d "$BACKEND_GO" ] || { log "backend-go not found at $BACKEND_GO (set BACKEND_GO)"; exit 1; }
  [ -d "$BOSUN" ] || { log "sibling bosun repo not found at $BOSUN"; exit 1; }
  log "building native binary (sources changed)…"
  ( cd "$QM" && spago build ) >&2 || { log "spago build failed"; exit 1; }
  log "backend-go transpile (corefn -> Go, pruned to $MAIN)"
  rm -rf "$OUT"
  ( cd "$BACKEND_GO" && spago run -- --corefn-dir "$QM/output" --output-dir "$OUT" --main "$MAIN" ) >&2 \
    || { log "backend-go transpile failed"; exit 1; }
  cp "$BACKEND_GO/runtime.go" "$OUT/runtime.go"
  # library decode foreigns (shared, from the sibling bosun repo)
  cp "$BOSUN"/conformance/go/argonaut_core_foreign.go   "$OUT/"
  cp "$BOSUN"/conformance/go/argonaut_parser_foreign.go "$OUT/"
  cp "$BOSUN"/conformance/go/foreign_object_foreign.go  "$OUT/"
  # Quartermaster's own CLI-edge twins (REAL Quartermaster_CLI_* symbols)
  cp "$QM"/cli/go/quartermaster_io_foreign.go    "$OUT/"
  cp "$QM"/cli/go/quartermaster_probe_foreign.go "$OUT/"
  cp "$QM"/cli/go/quartermaster_build_foreign.go "$OUT/"
  log "go build ($(ls "$OUT"/*.go | wc -l | tr -d ' ') Go files; yaml.v3 from cache)"
  (
    cd "$OUT"
    go mod init gnomonquartermaster >/dev/null 2>&1
    go mod edit -require=gopkg.in/yaml.v3@"$YAML_VERSION"
    GOFLAGS=-mod=mod go build -o "$BIN" .
  ) >/tmp/gnomon-quartermaster-build.err 2>&1 || { log "go build failed — see /tmp/gnomon-quartermaster-build.err"; cat /tmp/gnomon-quartermaster-build.err >&2; exit 1; }
  log "built $BIN"
}

stale && build
exec "$BIN" "$@"
