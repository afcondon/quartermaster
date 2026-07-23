#!/usr/bin/env bash
# Compile the PureScript recipe through Nyx, then prove it produces
# derivation-hash-identical devShells + packages to the hand-written
# flake.nix. Run from anywhere.
#
# B layout (data axis): the `nix` column is isolated — it depends only on the
# Prim-only `core` (the IR) and adds ToNix. So `spago build` in the column
# compiles EXACTLY IR + ToNix (both Prim-only), and no ToDocs/Main/prelude is in
# scope — which is why the flat layout's throwing ToNix.js stub is no longer
# needed. Nyx (pursnix) then lowers that CoreFn to Nix.
set -euo pipefail
export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"
export NIX_CONFIG="experimental-features = nix-command flakes"

RECIPE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"     # provisioning/recipe
NIXCOL="$RECIPE_ROOT/columns/nix"
export QM_PATH="$(cd "$RECIPE_ROOT/../.." && pwd)"                 # the quartermaster repo root
export RECIPE_OUT="$NIXCOL/output/Quartermaster.Recipe.ToNix"

# pursnix (Nyx): env override, then PATH, then the purescript-nix sibling
# checkout relative to the afc-work root (QM_PATH/../..). No absolute paths.
PURSNIX="${PURSNIX:-$(command -v pursnix || true)}"
[ -n "$PURSNIX" ] || PURSNIX="$(ls "$QM_PATH"/../../purescript-backends/purescript-nix/.stack-work/install/*/*/*/bin/pursnix 2>/dev/null | head -1)"
[ -n "$PURSNIX" ] || { echo "FATAL: pursnix not found (set \$PURSNIX, put it on PATH, or cd purescript-nix && stack build)"; exit 1; }

cd "$NIXCOL"
echo "==> building nix column (purs $(purs --version); spago backend cmd:true -> CoreFn; IR + ToNix, both Prim-only)"
rm -rf output
spago build >/tmp/qm-recipe-verify.$$ 2>&1 || { echo "spago build FAILED:"; tail -20 /tmp/qm-recipe-verify.$$; rm -f /tmp/qm-recipe-verify.$$; exit 1; }
rm -f /tmp/qm-recipe-verify.$$
echo "==> Nyx: CoreFn -> Nix"
"$PURSNIX" output . >/dev/null

echo "==> comparing derivation hashes (recipe vs flake.nix)"
nix eval --impure --raw -f "$RECIPE_ROOT/verify.nix"
echo
