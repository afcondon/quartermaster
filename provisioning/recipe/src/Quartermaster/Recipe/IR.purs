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
-- Packages (symbolic references into nixpkgs + the purescript overlay)
--------------------------------------------------------------------------------

pursP :: Package
pursP = Package { name: "purs", path: [ "purs-bin", "purs-0_15_15" ] }

spagoP :: Package
spagoP = Package { name: "spago", path: [ "spago-unstable" ] }

pursTidyP :: Package
pursTidyP = Package { name: "purs-tidy", path: [ "purs-tidy" ] }

esbuildP :: Package
esbuildP = Package { name: "esbuild", path: [ "esbuild" ] }

plsP :: Package
plsP = Package { name: "purescript-language-server", path: [ "purescript-language-server" ] }

nodeP :: Package
nodeP = Package { name: "node", path: [ "nodejs_22" ] }

erlangP :: Package
erlangP = Package { name: "erlang", path: [ "erlang_28" ] }

rebar3P :: Package
rebar3P = Package { name: "rebar3", path: [ "rebar3" ] }

goP :: Package
goP = Package { name: "go", path: [ "go" ] }

goplsP :: Package
goplsP = Package { name: "gopls", path: [ "gopls" ] }

pythonP :: Package
pythonP = Package { name: "python", path: [ "python313" ] }

rustcP :: Package
rustcP = Package { name: "rustc", path: [ "rustc" ] }

cargoP :: Package
cargoP = Package { name: "cargo", path: [ "cargo" ] }

rustAnalyzerP :: Package
rustAnalyzerP = Package { name: "rust-analyzer", path: [ "rust-analyzer" ] }

ghcP :: Package
ghcP = Package { name: "ghc", path: [ "haskell", "compiler", "ghc98" ] }

hlsP :: Package
hlsP = Package { name: "hls", path: [ "haskell", "packages", "ghc98", "haskell-language-server" ] }

cabalP :: Package
cabalP = Package { name: "cabal", path: [ "cabal-install" ] }

stackP :: Package
stackP = Package { name: "stack", path: [ "stack" ] }

ffmpegP :: Package
ffmpegP = Package { name: "ffmpeg", path: [ "ffmpeg" ] }

zlibP :: Package
zlibP = Package { name: "zlib", path: [ "zlib" ] }

gitP :: Package
gitP = Package { name: "git", path: [ "git" ] }

-- the everyday CLI kit bundled by `tools`
ghP :: Package
ghP = Package { name: "gh", path: [ "gh" ] }

fdP :: Package
fdP = Package { name: "fd", path: [ "fd" ] }

ripgrepP :: Package
ripgrepP = Package { name: "ripgrep", path: [ "ripgrep" ] }

clocP :: Package
clocP = Package { name: "cloc", path: [ "cloc" ] }

duckdbP :: Package
duckdbP = Package { name: "duckdb", path: [ "duckdb" ] }

cmakeP :: Package
cmakeP = Package { name: "cmake", path: [ "cmake" ] }

jqP :: Package
jqP = Package { name: "jq", path: [ "jq" ] }

treeP :: Package
treeP = Package { name: "tree", path: [ "tree" ] }

tmuxP :: Package
tmuxP = Package { name: "tmux", path: [ "tmux" ] }

pandocP :: Package
pandocP = Package { name: "pandoc", path: [ "pandoc" ] }

graphvizP :: Package
graphvizP = Package { name: "graphviz", path: [ "graphviz" ] }

exiftoolP :: Package
exiftoolP = Package { name: "exiftool", path: [ "exiftool" ] }

httpieP :: Package
httpieP = Package { name: "httpie", path: [ "httpie" ] }

direnvP :: Package
direnvP = Package { name: "direnv", path: [ "direnv" ] }

gitLfsP :: Package
gitLfsP = Package { name: "git-lfs", path: [ "git-lfs" ] }

ackP :: Package
ackP = Package { name: "ack", path: [ "ack" ] }

helixP :: Package
helixP = Package { name: "helix", path: [ "helix" ] }

nnnP :: Package
nnnP = Package { name: "nnn", path: [ "nnn" ] }

coreutilsP :: Package
coreutilsP = Package { name: "coreutils", path: [ "coreutils" ] }

gnusedP :: Package
gnusedP = Package { name: "gnused", path: [ "gnused" ] }

gettextP :: Package
gettextP = Package { name: "gettext", path: [ "gettext" ] }

tmateP :: Package
tmateP = Package { name: "tmate", path: [ "tmate" ] }

bazeliskP :: Package
bazeliskP = Package { name: "bazelisk", path: [ "bazelisk" ] }

asciidoctorP :: Package
asciidoctorP = Package { name: "asciidoctor", path: [ "asciidoctor" ] }

arduinoCliP :: Package
arduinoCliP = Package { name: "arduino-cli", path: [ "arduino-cli" ] }

--------------------------------------------------------------------------------
-- Shells
--------------------------------------------------------------------------------

purescriptShell :: Shell
purescriptShell = Shell
  { name: "purescript"
  , tools: [ pursP, spagoP, pursTidyP, nodeP, gitP ]
  , cLibs: []
  , why: "The lingua franca shell (also the default): purs pinned to 0.15.15, spago, tidy, node."
  }

rustShell :: Shell
rustShell = Shell
  { name: "rust"
  , tools: [ rustcP, cargoP ]
  , cLibs: []
  , why: "Rust toolchain for the Rust-authored subsystems (es9-daemon, link-spike, msm)."
  }

erlangShell :: Shell
erlangShell = Shell
  { name: "erlang"
  , tools: [ erlangP, rebar3P ]
  , cLibs: []
  , why: "The BEAM toolchain (Erlang 28 + rebar3) for purerl output."
  }

nodeShell :: Shell
nodeShell = Shell
  { name: "node"
  , tools: [ nodeP ]
  , cLibs: []
  , why: "Bare Node 22 for JS-backend output and Node-hosted tooling."
  }

goShell :: Shell
goShell = Shell
  { name: "go"
  , tools: [ goP, goplsP ]
  , cLibs: []
  , why: "Go toolchain + gopls for the Gnomon backend and Go-authored tools."
  }

haskellShell :: Shell
haskellShell = Shell
  { name: "haskell"
  , tools: [ ghcP, cabalP, stackP, hlsP, gitP ]
  , cLibs: [ zlibP ]
  , why: "One GHC (9.8.4) for the whole estate; cabal + stack + HLS. zlib for the streaming-commons link chain."
  }

purerlShell :: Shell
purerlShell = Shell
  { name: "purerl"
  , tools: [ erlangP, rebar3P, pursP, spagoP, pursTidyP, nodeP ]
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
      [ pursP
      , spagoP
      , pursTidyP
      , esbuildP
      , erlangP
      , rebar3P
      , plsP
      , nodeP
      , goP
      , pythonP
      , rustcP
      , cargoP
      , rustAnalyzerP
      , ghcP
      , cabalP
      , stackP
      , ffmpegP
      ]
  , tools: Bundle
      { name: "afc-cli-tools"
      , contents:
          [ ghP, fdP, ripgrepP, clocP, duckdbP
          , cmakeP, jqP, treeP, tmuxP, pandocP
          , graphvizP, exiftoolP, httpieP, direnvP
          , gitLfsP, ackP, helixP, nnnP
          , coreutilsP, gnusedP, gettextP, tmateP
          , bazeliskP, asciidoctorP, arduinoCliP
          ]
      }
  }
