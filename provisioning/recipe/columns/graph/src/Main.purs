-- | JS entry point for the `graph` lowering: fold the shared recipe value to a
-- | Graphviz DOT graph and print it. `bin/graph.sh` runs this and pipes stdout
-- | through `dot -Tsvg` to produce recipe.svg.
module Main where

import Prelude

import Effect (Effect)
import Effect.Console (log)
import Quartermaster.Recipe.IR (recipe)
import Quartermaster.Recipe.ToGraph (render)

main :: Effect Unit
main = log (render recipe)
