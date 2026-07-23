#!/usr/bin/env bash
# qm-menagerie — the Quartermaster analog of Bosun's Menagerie: behavioural tests
# that exercise the actual PROVISIONING muscle (host-capability probing) under
# CONTROLLED, MUTATING conditions, run on BOTH runtimes (node CLI and the Gnomon
# backend-go native binary) and asserted byte-identical.
#
# Bosun's Menagerie launched live specimen processes and watched supervision
# (launch/track/teardown) — the muscle there was os-exec. Quartermaster doesn't
# launch anything; its muscle is the PROBE edge (`command -v` / `test -d` /
# `test -x`, local or ssh-wrapped). So the specimens here are controlled HOST
# CONDITIONS, and each scenario FLIPS one (a runtime on/off PATH, a cwd that
# exists or not, a binary that's executable or not) and asserts the verdict moves
# the right way — identically under node and gnomon.
#
# Why this catches what scripts/qm-conformance.sh (the static byte-diff) cannot:
# conformance runs against fixtures whose host state is whatever the dev box
# happens to have (python3 present, /srv/* absent), so the ABSENCE path of the
# probe foreign — `command -v <missing>` exits nonzero → node execSync throws,
# Go exec returns err, both must land on `RuntimeMissing` — is never exercised on
# a controlled positive→negative flip. The Menagerie sets up the absence on
# purpose. (This is the same reason Bosun's Menagerie caught the setsid/zombie
# fidelity bugs a byte-diff missed.)
#
# Hermetic: builds a throwaway stage (mktemp) with fake `quux`/`blob` binaries, a
# work dir, an empty compose and a specimen registry referencing the stage. No
# committed machine-specific paths; cleans up on exit. Offline by default —
# set QM_MEN_REMOTE=1 to add a macmini-hosted specimen that exercises the
# ssh-wrapped probe through the Go shProbe twin (read-only against the mini).
#
# Usage:  scripts/qm-menagerie.sh           (builds the gnomon binary if stale)
#         QM_MEN_REMOTE=1 scripts/qm-menagerie.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QM="$(cd "$HERE/.." && pwd)"
G="${BIN:-/tmp/gnomon-quartermaster}"

STAGE="$(mktemp -d /tmp/qm-menagerie.XXXXXX)"
export BIN_DIR="$STAGE/bin" WORK="$STAGE/work"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$BIN_DIR" "$WORK"

# Prepend the stage's bin to PATH so the probe's child `sh -c "command -v quux"`
# (the local target has an empty envPrefix, so it inherits our env) sees the fake
# binaries — and stops seeing them the moment a scenario removes one.
export PATH="$BIN_DIR:$PATH"

mkfake(){ printf '#!/bin/sh\nexit 0\n' >"$BIN_DIR/$1"; chmod +x "$BIN_DIR/$1"; }
mkfake quux
mkfake blob

# An empty compose (verify ingests compose ∪ registry; the specimens are all
# registry rows, so the probe muscle is controllable from one file).
printf 'services: {}\n' >"$STAGE/compose.yml"

# The specimen registry. Each row's startCommand classifies to a distinct
# ProbeSpec (see Quartermaster.Runtime): `cd <abs> && quux …` → CommandOnPath
# "quux" + cwd; `cd <abs> && <abs>/blob …` → FileExecutable; bare `quux …` (no cd)
# → CommandOnPath, no cwd; `cd <abs> &&` (empty command) → Unknown → Unclassified;
# bare `docker …` → Container → EngineAny.
write_registry(){
  local remote_row=""
  if [ "${QM_MEN_REMOTE:-0}" = "1" ]; then
    remote_row=',
    {"id":6,"role":"api","projectName":"remote","projectSlug":"remote","port":8195,"host":"examplehost","startCommand":"cd /srv/archive && node server.js --port 8195","url":"http://examplehost:8195"}'
  fi
  cat >"$STAGE/registry.json" <<EOF
{
  "servers": [
    {"id":1,"role":"svc","projectName":"onpath","projectSlug":"onpath","port":9991,"host":"mbp","startCommand":"cd $WORK && quux serve --port 9991","url":"http://localhost:9991"},
    {"id":2,"role":"svc","projectName":"binary","projectSlug":"binary","port":9992,"host":"mbp","startCommand":"cd $WORK && $BIN_DIR/blob run","url":"http://localhost:9992"},
    {"id":3,"role":"svc","projectName":"nocwd","projectSlug":"nocwd","port":9993,"host":"mbp","startCommand":"quux daemon","url":"http://localhost:9993"},
    {"id":4,"role":"svc","projectName":"unclassified","projectSlug":"unclassified","port":9994,"host":"mbp","startCommand":"cd $WORK && ","url":"http://localhost:9994"},
    {"id":5,"role":"svc","projectName":"container","projectSlug":"container","port":9995,"host":"mbp","startCommand":"docker compose up","url":"http://localhost:9995"}${remote_row}
  ]
}
EOF
}
write_registry

# Build/warm the gnomon binary (the wrapper rebuilds when stale, then runs).
BIN="$G" "$HERE/gnomon-quartermaster.sh" verify "$STAGE/compose.yml" "$STAGE/registry.json" >/dev/null

NODE_OUT="$STAGE/node.txt"; GO_OUT="$STAGE/go.txt"
fail=0

# Run verify under both runtimes against the current stage state, assert the two
# outputs are byte-identical (the fidelity invariant).
run_pair(){
  node "$QM/cli/run.js" verify "$STAGE/compose.yml" "$STAGE/registry.json" >"$NODE_OUT" 2>&1 || true
  "$G"                  verify "$STAGE/compose.yml" "$STAGE/registry.json" >"$GO_OUT"   2>&1 || true
  if ! diff -q "$NODE_OUT" "$GO_OUT" >/dev/null; then
    echo "    ✗ node ≢ gnomon:"; diff "$NODE_OUT" "$GO_OUT" | sed 's/^/        /'; fail=1; return 1
  fi
  return 0
}

# Ground-truth assertion against the (identical) output. Checking node suffices
# once run_pair has proven go is byte-identical.
want(){    grep -qF -- "$1" "$NODE_OUT" || { echo "    ✗ expected (missing): $1"; fail=1; }; }
wantnot(){ grep -qF -- "$1" "$NODE_OUT" && { echo "    ✗ unexpected (present): $1"; fail=1; } || true; }

scenario(){ echo; echo "▎ $1"; }
pass(){ [ "$fail" -eq 0 ] && echo "    ✓ node ≡ gnomon, verdict matches ground truth"; }

echo "qm-menagerie: provisioning muscle, dual-runtime (node ≡ gnomon)"
echo "  stage: $STAGE   remote: ${QM_MEN_REMOTE:-0}"

# ── S1: everything present ────────────────────────────────────────────────────
scenario "S1 all present — quux on PATH, blob executable, work/ exists"
run_pair && {
  want "✓ [mbp] onpath — quux ready"
  want "✓ [mbp] binary — $BIN_DIR/blob ready"
  want "✓ [mbp] nocwd — quux ready"
  want "✓ [mbp] container — container engine ready"
  want "✗ [mbp] unclassified"
  want "cannot classify launch command head"
  pass
}

# ── S2: runtime missing ───────────────────────────────────────────────────────
# Remove quux from the stage bin. command -v quux now exits nonzero — the absence
# path conformance never sees. Both quux-needing services must flip to
# RuntimeMissing; blob (a different probe) stays ready.
scenario "S2 runtime missing — remove quux from PATH"
rm -f "$BIN_DIR/quux"
run_pair && {
  want "✗ [mbp] onpath"
  want "runtime not on this host: quux (install it — Quartermaster's job)"
  want "✗ [mbp] nocwd"
  want "✓ [mbp] binary — $BIN_DIR/blob ready"
  pass
}

# ── S3: cwd missing ───────────────────────────────────────────────────────────
# quux back; remove the work dir. The two services with a cwd flip to CwdMissing;
# nocwd (no working directory) stays ready.
scenario "S3 cwd missing — restore quux, remove work/"
mkfake quux
rmdir "$WORK"
run_pair && {
  want "✗ [mbp] onpath"
  want "working directory does not exist: $WORK"
  want "✗ [mbp] binary"
  want "✓ [mbp] nocwd — quux ready"
  pass
}

# ── S4: binary not executable ─────────────────────────────────────────────────
# work back; strip the execute bit off blob. test -x fails → the FileExecutable
# probe flips to RuntimeMissing(BinaryAt); the CommandOnPath service is unaffected.
scenario "S4 binary not executable — restore work/, chmod -x blob"
mkdir -p "$WORK"
chmod -x "$BIN_DIR/blob"
run_pair && {
  want "✗ [mbp] binary"
  want "runtime not on this host: $BIN_DIR/blob (install it — Quartermaster's job)"
  want "✓ [mbp] onpath — quux ready"
  pass
}

# ── S5 (opt-in): remote ssh probe ─────────────────────────────────────────────
if [ "${QM_MEN_REMOTE:-0}" = "1" ]; then
  scenario "S5 remote — macmini specimen, ssh-wrapped probe via the Go shProbe twin"
  run_pair && {
    # node is installed on the mini (found over ssh, envPrefix-aware), but
    # /srv/archive doesn't exist → CwdMissing. The point is node ≡ gnomon over ssh.
    want "✗ [macmini] remote"
    want "working directory does not exist: /srv/archive"
    pass
  }
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "qm-menagerie: ALL SCENARIOS PASS ✓ — the probe muscle moves correctly, identically on node and gnomon."
else
  echo "qm-menagerie: FAILURES above."; exit 1
fi
