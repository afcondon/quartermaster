-- | The Nyx (PureScript -> Nix) interpreter of the shared recipe IR.
-- |
-- | It folds `IR.recipe` into `flake`, a Nix function of the package
-- | collection producing `{ devShells; packages; }` — the same shape the
-- | hand-written flake.nix produces, and proven byte-identical to it (same
-- | derivation hashes) by bin/verify.sh.
-- |
-- | Prim-only + FFIs: a foreign `Nix` type plus a handful of primitive Nix
-- | operations (co-located in ToNix.nix, copied by pursnix to foreign.nix).
-- | No prelude — the primitives ARE the vocabulary.
module Quartermaster.Recipe.ToNix where

import Quartermaster.Recipe.IR (Recipe(..), Shell(..), Bundle(..), Package(..), recipe)

-- | An opaque Nix value (a derivation, the package collection, an attrset...).
foreign import data Nix :: Type

-- | `pkgs.mkShell { packages = ...; buildInputs = ...; }`.
foreign import mkShell :: Nix -> { packages :: Array Nix, buildInputs :: Array Nix } -> Nix

-- | `pkgs.buildEnv { name = ...; paths = ...; }`.
foreign import buildEnv :: Nix -> { name :: String, paths :: Array Nix } -> Nix

-- | `builtins.listToAttrs` — a list of `{name,value}` into an attrset.
foreign import listToAttrs :: Array { name :: String, value :: Nix } -> Nix

-- | `builtins.map`, kept FFI to avoid pulling in a prelude Functor.
foreign import mapArray :: forall a b. (a -> b) -> Array a -> Array b

-- | Resolve a nixpkgs access path against a package set via `builtins.foldl'`.
foreign import attrByPath :: Array String -> Nix -> Nix

-- | `a ++ b` for arrays, Prim-side (no prelude Semigroup).
foreign import concatArray :: forall a. Array a -> Array a -> Array a

-- | `builtins.filter`.
foreign import filterArray :: forall a. (a -> Boolean) -> Array a -> Array a

-- | `builtins.head`.
foreign import head :: forall a. Array a -> a

-- | String equality (`==`), Prim-side (no prelude Eq).
foreign import stringEq :: String -> String -> Boolean

-- | The display/output name of a package.
pkgName :: Package -> String
pkgName (Package p) = p.name

-- | Resolve a symbolic `Package` to its derivation in the collection.
resolve :: Nix -> Package -> Nix
resolve pkgs (Package p) = attrByPath p.path pkgs

-- | The whole recipe as a Nix function of the package collection.
flake :: Nix -> { devShells :: Nix, packages :: Nix }
flake pkgs = build recipe
  where
  build (Recipe r) =
    let
      shellEntry (Shell s) =
        { name: s.name
        , value: mkShell pkgs
            { packages: mapArray (resolve pkgs) s.tools
            , buildInputs: mapArray (resolve pkgs) s.cLibs
            }
        }
      shellEntries = mapArray shellEntry r.shells

      -- the `default` devShell is the same derivation as the shell named
      -- `defaultShell` (mirrors flake.nix's `rec { ...; default = purescript; }`)
      isDefault e = stringEq e.name r.defaultShell
      defaultEntry = head (filterArray isDefault shellEntries)
      devShells = listToAttrs
        (concatArray shellEntries [ { name: "default", value: defaultEntry.value } ])

      pkgEntry p = { name: pkgName p, value: resolve pkgs p }
      pkgEntries = mapArray pkgEntry r.packages

      toolsEntry (Bundle b) =
        { name: "tools"
        , value: buildEnv pkgs { name: b.name, paths: mapArray (resolve pkgs) b.contents }
        }
      packages = listToAttrs (concatArray pkgEntries [ toolsEntry r.tools ])
    in
      { devShells, packages }
