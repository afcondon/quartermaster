-- | JS-backend entry point: render the shared recipe IR to Markdown and print
-- | it. Run via bin/docs.sh (`spago run`). Proves the SAME `IR.recipe` value
-- | that Nyx compiles to flake.nix also renders as documentation.
module Main where

import Prelude

import Effect (Effect)
import Effect.Console (log)
import Quartermaster.Recipe.IR (recipe)
import Quartermaster.Recipe.ToDocs (render)

main :: Effect Unit
main = log (render recipe)
