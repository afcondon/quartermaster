-- | Quartermaster's toolchain recipe, authored in PureScript.
-- |
-- | This is the substrate's provisioning recipe — which tools go in each work
-- | environment — written in PureScript instead of by hand in Nix. The Nyx
-- | backend (purescript -> Nix) translates it; `flake` becomes a Nix function
-- | of the package collection, and each `mkShell`/`buildEnv` call becomes the
-- | corresponding Nix derivation. It is proven byte-identical (same derivation
-- | hashes) to the hand-written flake.nix outputs — see provisioning/recipe/
-- | bin/verify.sh.
-- |
-- | Prim-only: a foreign `Derivation` type plus records and arrays, exactly the
-- | shapes Nyx lowers natively. No prelude, no FFI file — the package
-- | collection (with mkShell/buildEnv and every package) is passed in.
module Quartermaster.Recipe where

-- | An opaque Nix derivation (a buildable thing: a tool, a shell, a bundle).
foreign import data Derivation :: Type

-- | The subset of the Nix package collection this recipe names. The real
-- | collection (nixpkgs + the purescript overlay, thousands of attrs) is a
-- | superset, which Nix accepts. Names match nixpkgs exactly — hyphens and
-- | nesting and all — via quoted/nested labels.
type Pkgs =
  { "purs-bin" :: { "purs-0_15_15" :: Derivation }
  , "spago-unstable" :: Derivation
  , "purs-tidy" :: Derivation
  , esbuild :: Derivation
  , "purescript-language-server" :: Derivation
  , nodejs_22 :: Derivation
  , erlang_28 :: Derivation
  , rebar3 :: Derivation
  , go :: Derivation
  , gopls :: Derivation
  , python313 :: Derivation
  , rustc :: Derivation
  , cargo :: Derivation
  , "rust-analyzer" :: Derivation
  , "cabal-install" :: Derivation
  , stack :: Derivation
  , ffmpeg :: Derivation
  , zlib :: Derivation
  , git :: Derivation
  , haskell ::
      { compiler :: { ghc98 :: Derivation }
      , packages :: { ghc98 :: { "haskell-language-server" :: Derivation } }
      }
  -- the everyday CLI kit bundled by `tools`
  , gh :: Derivation
  , fd :: Derivation
  , ripgrep :: Derivation
  , cloc :: Derivation
  , duckdb :: Derivation
  , cmake :: Derivation
  , jq :: Derivation
  , tree :: Derivation
  , tmux :: Derivation
  , pandoc :: Derivation
  , graphviz :: Derivation
  , exiftool :: Derivation
  , httpie :: Derivation
  , direnv :: Derivation
  , "git-lfs" :: Derivation
  , ack :: Derivation
  , helix :: Derivation
  , nnn :: Derivation
  , coreutils :: Derivation
  , gnused :: Derivation
  , gettext :: Derivation
  , tmate :: Derivation
  , bazelisk :: Derivation
  , asciidoctor :: Derivation
  , "arduino-cli" :: Derivation
  -- the two builder operations, taken from the collection itself
  , mkShell :: { packages :: Array Derivation, buildInputs :: Array Derivation } -> Derivation
  , buildEnv :: { name :: String, paths :: Array Derivation } -> Derivation
  }

-- | The whole recipe: given the package collection, produce the environments
-- | and individual tool binaries. Nyx compiles this to `pkgs: { devShells = ...;
-- | packages = ...; }`, which flake.nix can use in place of its hand-written
-- | devShells/packages.
flake
  :: Pkgs
  -> { devShells ::
         { purescript :: Derivation
         , rust :: Derivation
         , erlang :: Derivation
         , node :: Derivation
         , go :: Derivation
         , haskell :: Derivation
         , purerl :: Derivation
         , default :: Derivation
         }
     , packages ::
         { purs :: Derivation
         , spago :: Derivation
         , "purs-tidy" :: Derivation
         , esbuild :: Derivation
         , erlang :: Derivation
         , rebar3 :: Derivation
         , "purescript-language-server" :: Derivation
         , node :: Derivation
         , go :: Derivation
         , python :: Derivation
         , rustc :: Derivation
         , cargo :: Derivation
         , "rust-analyzer" :: Derivation
         , ghc :: Derivation
         , cabal :: Derivation
         , stack :: Derivation
         , ffmpeg :: Derivation
         , tools :: Derivation
         }
     }
flake pkgs =
  let
    -- readable aliases for the overlay-sourced + nested tools (let-binding is
    -- transparent to Nix, so derivation hashes are unaffected)
    purs = pkgs."purs-bin"."purs-0_15_15"
    spago = pkgs."spago-unstable"
    pursTidy = pkgs."purs-tidy"
    node = pkgs.nodejs_22
    erlang = pkgs.erlang_28
    rebar3 = pkgs.rebar3
    ghc98 = pkgs.haskell.compiler.ghc98
    hls = pkgs.haskell.packages.ghc98."haskell-language-server"

    shell :: Array Derivation -> Array Derivation -> Derivation
    shell packages buildInputs = pkgs.mkShell { packages, buildInputs }

    -- the lingua franca shell, also the default; bound once so both keys are
    -- the same derivation (mirrors the flake's `rec { ...; default = purescript; }`)
    purescriptShell = shell [ purs, spago, pursTidy, node, pkgs.git ] []
  in
    { devShells:
        { purescript: purescriptShell
        , rust: shell [ pkgs.rustc, pkgs.cargo ] []
        , erlang: shell [ erlang, rebar3 ] []
        , node: shell [ node ] []
        , go: shell [ pkgs.go, pkgs.gopls ] []
        , haskell: shell [ ghc98, pkgs."cabal-install", pkgs.stack, hls, pkgs.git ] [ pkgs.zlib ]
        , purerl: shell [ erlang, rebar3, purs, spago, pursTidy, node ] []
        , default: purescriptShell
        }
    , packages:
        { purs
        , spago
        , "purs-tidy": pursTidy
        , esbuild: pkgs.esbuild
        , erlang
        , rebar3
        , "purescript-language-server": pkgs."purescript-language-server"
        , node
        , go: pkgs.go
        , python: pkgs.python313
        , rustc: pkgs.rustc
        , cargo: pkgs.cargo
        , "rust-analyzer": pkgs."rust-analyzer"
        , ghc: ghc98
        , cabal: pkgs."cabal-install"
        , stack: pkgs.stack
        , ffmpeg: pkgs.ffmpeg
        , tools: pkgs.buildEnv
            { name: "afc-cli-tools"
            , paths:
                [ pkgs.gh, pkgs.fd, pkgs.ripgrep, pkgs.cloc, pkgs.duckdb
                , pkgs.cmake, pkgs.jq, pkgs.tree, pkgs.tmux, pkgs.pandoc
                , pkgs.graphviz, pkgs.exiftool, pkgs.httpie, pkgs.direnv
                , pkgs."git-lfs", pkgs.ack, pkgs.helix, pkgs.nnn
                , pkgs.coreutils, pkgs.gnused, pkgs.gettext, pkgs.tmate
                , pkgs.bazelisk, pkgs.asciidoctor, pkgs."arduino-cli"
                ]
            }
        }
    }
