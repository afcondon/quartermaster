#!/usr/bin/env bash
# qm-conformance — assert the node CLI and the Gnomon (backend-go native) binary
# produce BYTE-IDENTICAL output for every Quartermaster verb, over a spread of
# Bosun fixtures. The regression lock for the dual-runtime guarantee (the analog
# of bosun/scripts/go-conformance.sh + menagerie-conf.sh).
#
# Covers: verify (all-Process, all-Container, and mixed mbp+macmini — the last
# exercises the ssh-wrapped, envPrefix-aware probe through the Go shProbe twin,
# read-only against the mini) and build --dry-run (a build-context fixture).
#
# Output ordering is made deterministic in the pure core (Verify.requirementsOf
# sorts by host,service), so a passing diff proves the Go column matches node
# exactly — not merely "same set, different order".
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
BIN="$G" "$HERE/gnomon-quartermaster.sh" \
  verify "$FIX/menagerie/compose.yml" "$FIX/menagerie/registry.json" >/dev/null

fail=0
assert_identical(){   # <label> <verb> <fixture-dir> [extra args…]
  local label="$1" verb="$2" dir="$3"; shift 3
  node "$QM/cli/run.js" "$verb" "$@" "$dir/compose.yml" "$dir/registry.json" >"$TMP/node.txt" 2>&1 || true
  "$G"                  "$verb" "$@" "$dir/compose.yml" "$dir/registry.json" >"$TMP/gnom.txt" 2>&1 || true
  if diff -q "$TMP/node.txt" "$TMP/gnom.txt" >/dev/null; then
    echo "  ✓ $label"
  else
    echo "  ✗ $label — node ≢ gnomon:"; diff "$TMP/node.txt" "$TMP/gnom.txt" | sed 's/^/      /'
    fail=1
  fi
}

echo "qm-conformance: node CLI ≡ gnomon (backend-go) binary"
echo
echo "verify:"
assert_identical "menagerie (all Process/python3)"     verify "$FIX/menagerie"
assert_identical "multihost (all Container)"           verify "$FIX/topologies/multihost"
assert_identical "live (mixed mbp+macmini, ssh probe)" verify "$FIX/topologies/live"
echo "build --dry-run:"
assert_identical "edge-missing (build context)"        build  "$FIX/topologies/edge-missing" --dry-run

echo
if [ "$fail" -eq 0 ]; then
  echo "qm-conformance: ALL IDENTICAL ✓ — Quartermaster runs Node-free, byte-for-byte."
else
  echo "qm-conformance: DIVERGENCE — see diffs above."; exit 1
fi
