-- | The `graph` interpreter of the shared recipe IR: it folds `IR.recipe` into
-- | a Graphviz DOT graph. Compiled by the ordinary JS backend (like `ToDocs`);
-- | `bin/graph.sh` pipes the output through `dot` to an SVG.
-- |
-- | This is the THIRD interpreter over the ONE source of truth — after `ToNix`
-- | (lowers the value to the flake proven byte-identical to flake.nix) and
-- | `ToDocs` (renders it to Markdown). It closes the trilogy the eDSL was meant
-- | to serve: (a) Nix, (b) a graphical representation, (c) documentation. And
-- | it earns its keep — the graph makes VISIBLE what the flat lists hide: which
-- | tools are SHARED across shells (purs in purescript+purerl, erlang in
-- | erlang+purerl, node almost everywhere). Adding it was purely append-only:
-- | one new column, `core/` untouched.
module Quartermaster.Recipe.ToGraph (render) where

import Prelude

import Data.Array (concat, concatMap, elem, filter, length, nub)
import Data.String.Common (joinWith)
import Quartermaster.Recipe.IR (Recipe(..), Shell(..), Bundle(..), Package(..))

render :: Recipe -> String
render (Recipe r) = joinWith "\n" $
  [ "digraph recipe {"
  , "  rankdir=LR;"
  , "  labelloc=t;"
  , "  label=\"Quartermaster toolchain — shells and the tools they share\";"
  , "  fontname=\"Helvetica\"; fontsize=14;"
  , "  node [fontname=\"Helvetica\", fontsize=10];"
  , "  edge [color=\"#9aa0a6\"];"
  , ""
  ]
    <> map shellNode r.shells
    <> map toolNode toolNames
    <> [ bundleNode r.tools ]
    <> [ "" ]
    <> concatMap shellEdges r.shells
    <> bundleEdges r.tools
    <> [ "}" ]
  where
  -- every distinct package that appears anywhere becomes one tool node
  toolNames :: Array String
  toolNames = nub $ map pkgName $ concat
    [ concatMap shellTools r.shells
    , concatMap shellCLibs r.shells
    , r.packages
    , bundleContents r.tools
    ]

  shellTools (Shell s) = s.tools
  shellCLibs (Shell s) = s.cLibs
  bundleContents (Bundle b) = b.contents

  shellNode (Shell s) =
    "  " <> shellId s.name
      <> " [label=\"" <> s.name <> "\", shape=box, style=filled, fillcolor=\"#dbe9ff\"];"

  -- how many shells put this tool on PATH (via tools or cLibs)
  shellUses n (Shell s) = elem n (map pkgName (s.tools <> s.cLibs))
  usedByShells n = length (filter (shellUses n) r.shells)

  -- colour by sharing: amber+bold for a tool ≥2 shells share (the thing the
  -- flat lists hide), pale for a single-shell tool, white for bundle-only.
  toolNode n =
    let
      c = usedByShells n
      style
        | c >= 2 = "style=filled, fillcolor=\"#ffd54a\", penwidth=2"
        | c == 1 = "style=filled, fillcolor=\"#eef2f7\""
        | otherwise = "style=filled, fillcolor=\"#ffffff\""
    in
      "  " <> toolId n <> " [label=\"" <> n <> "\", shape=ellipse, " <> style <> "];"

  bundleNode (Bundle b) =
    "  " <> bundleId b.name
      <> " [label=\"" <> b.name <> "\", shape=box3d, style=filled, fillcolor=\"#ffe9c7\"];"

  shellEdges (Shell s) =
    map (\t -> "  " <> shellId s.name <> " -> " <> toolId (pkgName t) <> ";") s.tools
      <> map (\c -> "  " <> shellId s.name <> " -> " <> toolId (pkgName c)
                <> " [style=dashed, color=\"#c0392b\"];") s.cLibs

  bundleEdges (Bundle b) =
    map (\c -> "  " <> bundleId b.name <> " -> " <> toolId (pkgName c)
          <> " [color=\"#e67e22\"];") b.contents

-- node-id constructors: distinct namespaces so a shell and a tool that share a
-- name (the `node` shell vs the `node` package) never collide; DOT-quoted so
-- hyphens (purs-tidy) are fine.
shellId :: String -> String
shellId n = "\"shell:" <> n <> "\""

toolId :: String -> String
toolId n = "\"tool:" <> n <> "\""

bundleId :: String -> String
bundleId n = "\"bundle:" <> n <> "\""

pkgName :: Package -> String
pkgName (Package p) = p.name
