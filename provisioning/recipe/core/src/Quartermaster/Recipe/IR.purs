-- | Quartermaster's toolchain recipe as a backend-neutral data structure.
-- |
-- | This module is the single source of truth: which tools go in each work
-- | environment, and which individual tool binaries the substrate publishes.
-- | It is deliberately **Prim-only** — no prelude import, only ADTs, records,
-- | arrays and strings — so the SAME `.purs` compiles under BOTH backends:
-- |
-- |   * Nyx (PureScript -> Nix), via `ToNix`, which folds this IR into the
-- |     `flake` function proven byte-identical to the hand-written flake.nix;
-- |   * the JS backend, via `ToDocs`, which folds this IR into Markdown docs.
-- |
-- | One value (`recipe`), two interpreters. A `Package` is named symbolically:
-- | a display/output name plus the nixpkgs access path, so `ToNix` can resolve
-- | it against the package collection and `ToDocs` can simply print the name.
module Quartermaster.Recipe.IR where

-- | A package referenced symbolically. `name` is the display/output name
-- | (also the key used in the flake's `packages` output); `path` is the
-- | nixpkgs access path, e.g. `["haskell","compiler","ghc98"]` for
-- | `pkgs.haskell.compiler.ghc98`.
newtype Package = Package { name :: String, path :: Array String }

-- | A development shell: a name, the tools on `PATH` (`mkShell.packages`),
-- | any C libraries to link against (`mkShell.buildInputs`), and an honest
-- | one-line note on why the shell exists.
data Shell = Shell
  { name :: String
  , tools :: Array Package
  , cLibs :: Array Package
  , why :: String
  }

-- | An aggregate bundle built with `buildEnv`. `name` is the derivation name
-- | (load-bearing for the hash), `contents` the packages it unions.
newtype Bundle = Bundle { name :: String, contents :: Array Package }

-- | The whole recipe.
data Recipe = Recipe
  { shells :: Array Shell
  , defaultShell :: String     -- name of the shell that is also `default`
  , packages :: Array Package  -- the `packages` flake output (keyed by name)
  , tools :: Bundle            -- becomes packages.tools = buildEnv
  }

--------------------------------------------------------------------------------
-- Catalog. Two constructors do all the work:
--   from      — the display name IS the nixpkgs attribute (the common case)
--   as name   — a display name mapped onto a different / nested nixpkgs path
--------------------------------------------------------------------------------

-- | A package whose display name equals its (single-segment) nixpkgs attr.
from :: String -> Package
from n = Package { name: n, path: [ n ] }

-- | A package published under `name` but sourced from a different nixpkgs
-- | attribute path (overlay names, version-pinned attrs, nested sets).
as :: String -> Array String -> Package
as name path = Package { name, path }

-- overlay / version-pinned / nested (name ≠ path)
purs   = as "purs"   [ "purs-bin", "purs-0_15_15" ]
spago  = as "spago"  [ "spago-unstable" ]
node   = as "node"   [ "nodejs_22" ]
erlang = as "erlang" [ "erlang_28" ]
python = as "python" [ "python313" ]
cabal  = as "cabal"  [ "cabal-install" ]
ghc    = as "ghc"    [ "haskell", "compiler", "ghc98" ]
hls    = as "hls"    [ "haskell", "packages", "ghc98", "haskell-language-server" ]

-- name == nixpkgs attribute (incl. hyphenated attrs, which need no remapping)
pursTidy      = from "purs-tidy"
pls           = from "purescript-language-server"
rustAnalyzer  = from "rust-analyzer"
esbuild       = from "esbuild"
rebar3        = from "rebar3"
go            = from "go"
gopls         = from "gopls"
rustc         = from "rustc"
cargo         = from "cargo"
stack         = from "stack"
ffmpeg        = from "ffmpeg"
zlib          = from "zlib"
git           = from "git"

-- the everyday CLI kit bundled by `tools`
gh = from "gh"
fd = from "fd"
ripgrep = from "ripgrep"
cloc = from "cloc"
duckdb = from "duckdb"
cmake = from "cmake"
jq = from "jq"
tree = from "tree"
tmux = from "tmux"
pandoc = from "pandoc"
graphviz = from "graphviz"
exiftool = from "exiftool"
httpie = from "httpie"
direnv = from "direnv"
gitLfs = from "git-lfs"
ack = from "ack"
helix = from "helix"
nnn = from "nnn"
coreutils = from "coreutils"
gnused = from "gnused"
gettext = from "gettext"
tmate = from "tmate"
bazelisk = from "bazelisk"
asciidoctor = from "asciidoctor"
arduinoCli = from "arduino-cli"

--------------------------------------------------------------------------------
-- Shells
--------------------------------------------------------------------------------

purescriptShell :: Shell
purescriptShell = Shell
  { name: "purescript"
  , tools: [ purs, spago, pursTidy, node, git ]
  , cLibs: []
  , why: "The lingua franca shell (also the default): purs pinned to 0.15.15, spago, tidy, node."
  }

rustShell :: Shell
rustShell = Shell
  { name: "rust"
  , tools: [ rustc, cargo ]
  , cLibs: []
  , why: "Rust toolchain for the Rust-authored subsystems (es9-daemon, link-spike, msm)."
  }

erlangShell :: Shell
erlangShell = Shell
  { name: "erlang"
  , tools: [ erlang, rebar3 ]
  , cLibs: []
  , why: "The BEAM toolchain (Erlang 28 + rebar3) for purerl output."
  }

nodeShell :: Shell
nodeShell = Shell
  { name: "node"
  , tools: [ node ]
  , cLibs: []
  , why: "Bare Node 22 for JS-backend output and Node-hosted tooling."
  }

goShell :: Shell
goShell = Shell
  { name: "go"
  , tools: [ go, gopls ]
  , cLibs: []
  , why: "Go toolchain + gopls for the Gnomon backend and Go-authored tools."
  }

haskellShell :: Shell
haskellShell = Shell
  { name: "haskell"
  , tools: [ ghc, cabal, stack, hls, git ]
  , cLibs: [ zlib ]
  , why: "One GHC (9.8.4) for the whole estate; cabal + stack + HLS. zlib for the streaming-commons link chain."
  }

purerlShell :: Shell
purerlShell = Shell
  { name: "purerl"
  , tools: [ erlang, rebar3, purs, spago, pursTidy, node ]
  , cLibs: []
  , why: "purerl-tidal needs BOTH the BEAM runtime and the PureScript toolchain — PS source targeting Erlang."
  }

--------------------------------------------------------------------------------
-- The recipe
--------------------------------------------------------------------------------

recipe :: Recipe
recipe = Recipe
  { shells:
      [ purescriptShell
      , rustShell
      , erlangShell
      , nodeShell
      , goShell
      , haskellShell
      , purerlShell
      ]
  , defaultShell: "purescript"
  , packages:
      [ purs, spago, pursTidy, esbuild, erlang, rebar3, pls, node, go
      , python, rustc, cargo, rustAnalyzer, ghc, cabal, stack, ffmpeg
      ]
  , tools: Bundle
      { name: "afc-cli-tools"
      , contents:
          [ gh, fd, ripgrep, cloc, duckdb
          , cmake, jq, tree, tmux, pandoc
          , graphviz, exiftool, httpie, direnv
          , gitLfs, ack, helix, nnn
          , coreutils, gnused, gettext, tmate
          , bazelisk, asciidoctor, arduinoCli
          ]
      }
  }
