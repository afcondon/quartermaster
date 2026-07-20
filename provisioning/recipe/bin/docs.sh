#!/usr/bin/env bash
# Render the shared recipe IR to Markdown via the JS backend — the second
# interpreter of the ONE source of truth (`Quartermaster.Recipe.IR.recipe`).
# The first is the Nyx path (bin/verify.sh) which lowers the SAME value to the
# flake proven byte-identical to flake.nix. Prints the Markdown and also saves
# it to docs.generated.md at the recipe root. Run from anywhere.
#
# B layout (data axis): the `docs` column depends on core + the prelude surface
# ToDocs uses; `spago run` here compiles core + ToDocs + Main and prints.
set -euo pipefail
export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"

RECIPE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # provisioning/recipe
cd "$RECIPE_ROOT/columns/docs"

echo "==> spago run (JS backend: ToDocs.render IR.recipe)" >&2
# `spago run` prints program stdout mixed with its own progress on stderr;
# capture only stdout for the Markdown.
spago run 2>/dev/null | tee "$RECIPE_ROOT/docs.generated.md"
