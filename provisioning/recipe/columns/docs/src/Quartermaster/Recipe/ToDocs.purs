-- | The JS-backend interpreter of the shared recipe IR: it folds `IR.recipe`
-- | into human-readable Markdown documentation.
-- |
-- | This is the second consumer of the ONE source of truth. Where `ToNix`
-- | lowers the same value to Nix derivations (proven byte-identical to
-- | flake.nix), `ToDocs` renders it to prose — demonstrating that the recipe
-- | is genuinely backend-neutral data, not Nix in disguise.
module Quartermaster.Recipe.ToDocs (render) where

import Prelude

import Data.Array (concat)
import Data.String.Common (joinWith)
import Quartermaster.Recipe.IR (Recipe(..), Shell(..), Bundle(..), Package(..))

render :: Recipe -> String
render (Recipe r) = joinWith "\n" $
  [ "# Quartermaster toolchain recipe"
  , ""
  , "Generated from the shared `Quartermaster.Recipe.IR` value via the JS backend"
  , "(`ToDocs.render`). The SAME value compiles through Nyx to the flake proven"
  , "byte-identical to the hand-written `flake.nix` (`ToNix.flake`)."
  , ""
  , "Default shell: **" <> r.defaultShell <> "**"
  , ""
  , "## Development shells"
  , ""
  ]
    <> concat (map shellSection r.shells)
    <> [ "## Packages"
       , ""
       , "Individual tool binaries published as `packages.<name>`:"
       , ""
       ]
    <> map (bullet <<< pkgLabel) r.packages
    <> [ ""
       , "## Tools bundle"
       , ""
       ]
    <> bundleLines r.tools

shellSection :: Shell -> Array String
shellSection (Shell s) =
  [ "### " <> s.name <> " shell"
  , ""
  , s.why
  , ""
  , "Tools: " <> joinWith ", " (map pkgLabel s.tools)
  ] <> cLibsLine s.cLibs

cLibsLine :: Array Package -> Array String
cLibsLine = case _ of
  [] -> [ "" ]
  cs -> [ "C libraries: " <> joinWith ", " (map pkgLabel cs), "" ]

bundleLines :: Bundle -> Array String
bundleLines (Bundle b) =
  [ "`" <> b.name <> "` (a `buildEnv` union of the everyday CLI kit):"
  , ""
  ] <> map (bullet <<< pkgLabel) b.contents

pkgLabel :: Package -> String
pkgLabel (Package p) = p.name

bullet :: String -> String
bullet s = "- " <> s
