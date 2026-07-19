#!/bin/sh
# qm-nix.sh — Quartermaster's Nix mandate, script-proven form.
# (The house pattern: build/publish were shell-proven live before
# becoming typed CLI verbs; `quartermaster nix` follows once this is.)
#
#   qm-nix.sh verify [host]     is Nix present, healthy, flake-capable?
#   qm-nix.sh ensure [host]     install (DetSys) if absent — needs a tty
#                               for sudo; remote ⇒ run under `ssh -t`
#   qm-nix.sh sync [host]       copy this flake's toolchain closures to
#                               the host (build-once-ship, Nix transport)
#   qm-nix.sh manifest [host]   realize the dev shells from the flake ON
#                               the host and print its store-path
#                               manifest (the replication test: two
#                               hosts, one lock, identical lists)
#
# host omitted = local. No machine-specific assumptions: `host` is any
# ssh destination; the fleet is arbitrary, the two Macs merely first.

set -eu

QM_DIR=$(cd "$(dirname "$0")/.." && pwd)
NIX_PROFILE_BIN="/nix/var/nix/profiles/default/bin"
INSTALL_URL="https://install.determinate.systems/nix"
SHELLS="purescript rust erlang node"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

cmd=${1:-}
host=${2:-}

# run a command on the target (local or ssh), with the nix profile on
# PATH — a bare non-interactive ssh shell has a thin PATH (the same
# lesson quartermaster verify learned with envPrefix)
run() {
  if [ -z "$host" ]; then
    sh -c "PATH=\"$NIX_PROFILE_BIN:\$PATH\"; $1"
  else
    # shellcheck disable=SC2029
    ssh "$host" "PATH=\"$NIX_PROFILE_BIN:\$PATH\"; $1"
  fi
}

where() { [ -z "$host" ] && echo "local" || echo "$host"; }

verify() {
  ok=0
  if v=$(run "nix --version" 2>/dev/null); then
    echo "  nix present:    OK ($v)"
  else
    echo "  nix present:    ABSENT"
    echo "$(where): NOT PROVISIONED (run: qm-nix.sh ensure $host)"
    return 1
  fi
  if run "nix store info" >/dev/null 2>&1 || run "nix store ping" >/dev/null 2>&1; then
    echo "  store healthy:  OK"
  else
    echo "  store healthy:  FAIL (store present but unreachable — broken /nix?)"
    ok=1
  fi
  if run "nix flake --help" >/dev/null 2>&1; then
    echo "  flakes:         OK"
  else
    echo "  flakes:         FAIL (nix present but flake-incapable)"
    ok=1
  fi
  # macOS hosts: Xcode CLT is a host fact outside Nix that native
  # builds (CoreAudio/cpal) still need — verify composes host facts
  if run "test \"\$(uname)\" = Darwin" 2>/dev/null; then
    if run "xcode-select -p" >/dev/null 2>&1; then
      echo "  xcode CLT:      OK (darwin host)"
    else
      echo "  xcode CLT:      MISSING (darwin host; xcode-select --install)"
      ok=1
    fi
  fi
  [ $ok -eq 0 ] && echo "$(where): PROVISIONED" || echo "$(where): UNHEALTHY"
  return $ok
}

ensure() {
  if run "nix --version" >/dev/null 2>&1; then
    echo "$(where): nix already present — nothing to do"
    return 0
  fi
  if [ -n "$host" ]; then
    if [ -t 0 ]; then
      echo "$(where): installing (DetSys) — sudo will prompt on the remote tty"
      # shellcheck disable=SC2029
      ssh -t "$host" "curl -fsSL $INSTALL_URL | sh -s -- install --no-confirm"
    else
      echo "$(where): needs a tty for sudo. Run:"
      echo "  ssh -t $host 'curl -fsSL $INSTALL_URL | sh -s -- install --no-confirm'"
      return 1
    fi
  else
    echo "local: installing (DetSys) — sudo will prompt"
    curl -fsSL "$INSTALL_URL" | sh -s -- install --no-confirm
  fi
}

# store paths behind the flake's dev shells, realized locally
local_manifest() {
  for s in $SHELLS; do
    PATH="$NIX_PROFILE_BIN:$PATH" nix develop "$QM_DIR#$s" --command sh -c 'echo "$PATH"' 2>/dev/null \
      | tr ':' '\n' | grep '^/nix/store' | sed 's|/bin$||'
  done | sort -u
}

sync() {
  [ -n "$host" ] || { echo "sync needs a host"; exit 2; }
  echo "realizing shells locally…"
  paths=$(local_manifest)
  n=$(echo "$paths" | wc -l | tr -d ' ')
  echo "copying $n toolchain closures to $host…"
  # shellcheck disable=SC2086
  PATH="$NIX_PROFILE_BIN:$PATH" nix copy --to "ssh://$host" $paths
  echo "done — verify with: qm-nix.sh manifest $host"
}

manifest() {
  if [ -z "$host" ]; then
    local_manifest
  else
    # the target evaluates the flake itself (reproducibility, not
    # transport): needs this repo present at the same relative spot,
    # else pass QM_REMOTE_DIR
    rdir=${QM_REMOTE_DIR:-$QM_DIR}
    for s in $SHELLS; do
      run "nix develop \"$rdir#$s\" --command sh -c 'echo \"\$PATH\"'" 2>/dev/null \
        | tr ':' '\n' | grep '^/nix/store' | sed 's|/bin$||'
    done | sort -u
  fi
}

case "$cmd" in
  verify) verify ;;
  ensure) ensure ;;
  sync) sync ;;
  manifest) manifest ;;
  *) usage ;;
esac
