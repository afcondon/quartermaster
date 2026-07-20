#!/usr/bin/env bash
# Compile the PureScript recipe through Nyx, then prove it produces
# derivation-hash-identical devShells + packages to the hand-written
# flake.nix. Run from anywhere.
set -euo pipefail
export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"
export NIX_CONFIG="experimental-features = nix-command flakes"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"          # provisioning/recipe
export QM_PATH="/Users/afc/work/afc-work/ShapedSteer/quartermaster"
export RECIPE_OUT="$ROOT/output/Quartermaster.Recipe"

PURSNIX="$(ls /Users/afc/work/afc-work/purescript-backends/purescript-nix/.stack-work/install/*/*/*/bin/pursnix 2>/dev/null | head -1)"
[ -n "$PURSNIX" ] || { echo "FATAL: pursnix not built (cd purescript-nix && stack build)"; exit 1; }

cd "$ROOT"
echo "==> compiling recipe (purs $(purs --version), Prim-only)"
rm -rf output
purs compile --codegen corefn 'src/**/*.purs' >/dev/null
echo "==> Nyx: CoreFn -> Nix"
"$PURSNIX" output . >/dev/null

echo "==> comparing derivation hashes (recipe vs flake.nix)"
nix eval --impure --raw -f verify.nix
echo
