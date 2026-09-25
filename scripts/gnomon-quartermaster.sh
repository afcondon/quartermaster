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
# Library foreigns (argonaut / foreign-object) come from backend-go's own
# `foreign/` layer, which `bin/backend-go` supplies. They used to be copied from
# the sibling Bosun repo's conformance/go, until Bosun moved them upstream on
# 2026-08-24 (bosun 7ead418); this script kept copying them, and its Go column
# stayed red for a month until `brew check` needed it (2026-09-25).
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
  # backend-go's runtime and per-package foreign/ layer, so an upstream fix
  # reaches the cached binary (the same watch gnomon-bosun.sh keeps)
  [ -n "$(find "$BACKEND_GO/runtime.go" "$BACKEND_GO/foreign" -newer "$BIN" -print -quit 2>/dev/null)" ] && return 0
  return 1
}

build(){
  [ -d "$BACKEND_GO" ] || { log "backend-go not found at $BACKEND_GO (set BACKEND_GO)"; exit 1; }
  [ -d "$BOSUN" ] || { log "sibling bosun repo not found at $BOSUN"; exit 1; }
  log "building native binary (sources changed)…"
  ( cd "$QM" && spago build ) >&2 || { log "spago build failed"; exit 1; }
  log "backend-go transpile (corefn -> Go, pruned to $MAIN)"
  rm -rf "$OUT"
  # CWD must be $QM: CoreFn modulePath is relative to where spago built, and
  # bin/backend-go resolves foreigns beside each .purs from it (Bosun's, for the
  # path-imported bosun-core) and adds the backend's own foreign/ layer.
  ( cd "$QM" && "$BACKEND_GO/bin/backend-go" --corefn-dir "$QM/output" --output-dir "$OUT" --main "$MAIN" ) >&2 \
    || { log "backend-go transpile failed"; exit 1; }
  cp "$BACKEND_GO/runtime.go" "$OUT/runtime.go"
  # Quartermaster's own CLI-edge twins (REAL Quartermaster_CLI_* symbols)
  cp "$QM"/cli/go/quartermaster_io_foreign.go    "$OUT/"
  cp "$QM"/cli/go/quartermaster_probe_foreign.go "$OUT/"
  cp "$QM"/cli/go/quartermaster_build_foreign.go "$OUT/"
  cp "$QM"/cli/go/quartermaster_apply_foreign.go  "$OUT/"
  cp "$QM"/cli/go/quartermaster_publish_foreign.go "$OUT/"
  cp "$QM"/cli/go/quartermaster_exec_foreign.go  "$OUT/"
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
