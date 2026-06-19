-- | Quartermaster's synchronous I/O edge — read a YAML/JSON file off disk into a
-- | `Json` for the (shared, path-imported) Bosun adapters to decode. The no-Aff
-- | seam: straight-line, lives at the edge, never in the pure core. Mirrors
-- | `Bosun.CLI.IO` (own symbols so Quartermaster stays decoupled from bosun-cli —
-- | it shares the model + adapters, not the whole CLI).
module Quartermaster.CLI.IO
  ( readYamlFile
  , readJsonFile
  , argv
  ) where

import Data.Argonaut.Core (Json)
import Effect (Effect)
import Effect.Uncurried (EffectFn1, runEffectFn1)

foreign import readYamlImpl :: EffectFn1 String Json
foreign import readJsonImpl :: EffectFn1 String Json
foreign import argv :: Effect (Array String)

readYamlFile :: String -> Effect Json
readYamlFile = runEffectFn1 readYamlImpl

readJsonFile :: String -> Effect Json
readJsonFile = runEffectFn1 readJsonImpl
