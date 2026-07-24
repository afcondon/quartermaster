#!/usr/bin/env bash
# qm-conformance — assert the node CLI and the Gnomon (backend-go native) binary
# produce BYTE-IDENTICAL output for EVERY Quartermaster verb, over a spread of
# Bosun fixtures. The regression lock for the dual-runtime guarantee (the analog
# of bosun/scripts/go-conformance.sh + menagerie-conf.sh).
#
# The coverage discipline (spec: docs/spec-conformance-every-verb.md): every verb
# the CLI dispatches gets a case, each a PURE / plan-only invocation (no outward
# side effects — the applyScript discipline means every verb has a pure plan to
# compare). If a whole verb's Go column is missing its FFI twins the link fails,
# the binary doesn't build — and because the harness rebuilds the binary as step 1
# under `set -euo pipefail`, a broken build is a conformance FAILURE, not a
# silently-skipped verb. Covers:
#
#   verify  — 3 fixtures (all-Process, all-Container, mixed mbp+macmini ssh probe)
#   build   — --dry-run, a build-context fixture AND a nothing-to-build fixture
#   publish — --dry-run, a static-CDN fixture (non-empty plan) AND the empty case
#   apply   — --dry-run --system <sys> [--shell …] <target> (linux+darwin, both shells)
#   exec    — --dry-run -- <cmd> (prints the script it would run; --dry-run parsed
#             BEFORE the `--` split, so it's never mistaken for the wrapped command)
#   usage   — no-args and unknown-verb (the same pure `usage` value both emit)
#
# Output ordering is made deterministic in the pure core (Verify.requirementsOf
# sorts by host,service), so a passing diff proves the Go column matches node
# exactly — not merely "same set, different order".
#
# ADDING OR CHANGING A VERB REQUIRES A CONFORMANCE CASE HERE — the same discipline
# bosun's go-conformance.sh enforces.
#
# Usage:  scripts/qm-conformance.sh           (builds the gnomon binary if stale)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QM="$(cd "$HERE/.." && pwd)"
FIX="$QM/../bosun/fixtures"
G="${BIN:-/tmp/gnomon-quartermaster}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Build the native binary if stale (the wrapper rebuilds, then runs); the warm-up
# run's output is discarded — we only want the binary cached at $G for the diffs.
# Under `set -e` a failed Go build (e.g. a missing FFI twin) aborts the whole
# harness here: a build failure IS a conformance failure.
BIN="$G" "$HERE/gnomon-quartermaster.sh" \
  verify "$FIX/menagerie/compose.yml" "$FIX/menagerie/registry.json" >/dev/null

fail=0

# assert_raw <label> -- <full argv…> — run the SAME argv through node and gnomon
# and diff. The general form: any verb, any argument shape (targets, `--` command
# tails, bare flags), not only the <compose> <registry> pair.
assert_raw(){
  local label="$1"; shift
  [ "${1:-}" = "--" ] && shift
  node "$QM/cli/run.js" "$@" >"$TMP/node.txt" 2>&1 || true
  "$G"                  "$@" >"$TMP/gnom.txt" 2>&1 || true
  if diff -q "$TMP/node.txt" "$TMP/gnom.txt" >/dev/null; then
    echo "  ✓ $label"
  else
    echo "  ✗ $label — node ≢ gnomon:"; diff "$TMP/node.txt" "$TMP/gnom.txt" | sed 's/^/      /'
    fail=1
  fi
}

# assert_identical <label> <verb> <fixture-dir> [extra args…] — the compose/registry
# shape, now a thin wrapper over assert_raw.
assert_identical(){
  local label="$1" verb="$2" dir="$3"; shift 3
  assert_raw "$label" -- "$verb" "$@" "$dir/compose.yml" "$dir/registry.json"
}

echo "qm-conformance: node CLI ≡ gnomon (backend-go) binary"
echo

echo "verify:"
assert_identical "menagerie (all Process/python3)"     verify "$FIX/menagerie"
assert_identical "multihost (all Container)"           verify "$FIX/topologies/multihost"
assert_identical "live (mixed mbp+macmini, ssh probe)" verify "$FIX/topologies/live"

echo "build --dry-run:"
assert_identical "edge-missing (build context)"        build  "$FIX/topologies/edge-missing" --dry-run
assert_identical "menagerie (nothing to build)"        build  "$FIX/menagerie"               --dry-run

echo "publish --dry-run:"
assert_identical "static-cdn-widgets (non-empty plan)" publish "$FIX/static-cdn-widgets"     --dry-run
assert_identical "menagerie (empty plan)"              publish "$FIX/menagerie"              --dry-run

echo "apply --dry-run:"
assert_raw "linux, default shell (bash)"   -- apply --dry-run --system x86_64-linux                local
assert_raw "linux, --shell zsh"            -- apply --dry-run --system x86_64-linux --shell zsh    local
assert_raw "darwin, --shell bash"          -- apply --dry-run --system aarch64-darwin --shell bash local
assert_raw "darwin, --shell zsh"           -- apply --dry-run --system aarch64-darwin --shell zsh  local

echo "exec --dry-run:"
assert_raw "bare passthrough (spago build)" -- exec --dry-run -- spago build
assert_raw "flake dev-shell + argv"         -- exec --dry-run --flake ./repo#dev -- echo hi there

echo "usage:"
assert_raw "no args"      --
assert_raw "unknown verb" -- frobnicate --nonsense

echo
if [ "$fail" -eq 0 ]; then
  echo "qm-conformance: ALL IDENTICAL ✓ — Quartermaster runs Node-free, byte-for-byte."
else
  echo "qm-conformance: DIVERGENCE — see diffs above."; exit 1
fi
