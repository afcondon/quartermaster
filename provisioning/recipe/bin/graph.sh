#!/usr/bin/env bash
# Render the shared recipe IR to a Graphviz graph via the JS backend — the
# THIRD interpreter of the ONE source of truth (`Quartermaster.Recipe.IR.recipe`),
# after the Nyx path (bin/verify.sh) and the docs path (bin/docs.sh). Emits the
# DOT to recipe.dot and, if `dot` is on PATH, an SVG to recipe.svg (both at the
# recipe root). Run from anywhere.
set -euo pipefail
export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"

RECIPE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # provisioning/recipe
cd "$RECIPE_ROOT/columns/graph"

echo "==> spago run (JS backend: ToGraph.render IR.recipe)" >&2
spago run 2>/dev/null > "$RECIPE_ROOT/recipe.dot"
echo "==> wrote recipe.dot" >&2

if command -v dot >/dev/null 2>&1; then
  dot -Tsvg "$RECIPE_ROOT/recipe.dot" -o "$RECIPE_ROOT/recipe.svg"
  echo "==> wrote recipe.svg (graphviz $(dot -V 2>&1 | sed 's/.*version //'))" >&2
else
  echo "==> dot not on PATH; render with: dot -Tsvg recipe.dot -o recipe.svg" >&2
  echo "    (graphviz is in the substrate's 'tools' bundle / a devShell)" >&2
fi
