-- | The provision half of the seam (`quartermaster apply`) — bring a target
-- | host to the toolchain-floor par. The missing sibling to verify/build/publish:
-- | where `verify` reports whether a host is READY, `apply` MAKES it ready —
-- | ignition (install Nix) then convergence (install the par pins from the flake).
-- |
-- | This is the BASE PATH the fleet proved on BlackStar (x86_64-linux, 2026-07-23):
-- | the target self-substitutes from a public pinned flake ref, no same-arch
-- | builder, no inbound copy. Signed-closures (mini-par.sh) are the same-arch
-- | FAST-PATH optimisation, not modelled here.
-- |
-- | The PLAN is pure command strings (the applyScript discipline — display and
-- | execution never drift); the ssh/local wrapping + running is the CLI edge's
-- | job (`Quartermaster.CLI.Apply`), exactly as Bosun keeps `applyScript` pure.
module Quartermaster.Apply
  ( Shell(..)
  , ApplySpec
  , ApplyStep
  , Confidence(..)
  , parPins
  , nixDirenvPin
  , nixSystem
  , classify
  , confidenceLabel
  , applyPlan
  , applyInvocation
  , renderPlan
  ) where

import Prelude

import Bosun.Target (ExecLoc(..), Target, unSshDest)
import Data.Array as A
import Data.Foldable (intercalate)
import Data.Maybe (Maybe(..))

-- | The Target Support Catalog's confidence gradient (the MISU gate). Only
-- | `KnownGood` provisions without ceremony; everything else demands an explicit
-- | override that NAMES what it's overriding. A below-known-good install that
-- | goes green is promoted to known-good — the catalog is earned, not asserted.
data Confidence = KnownGood | LikelyGood | Unknown | KnownBad

derive instance eqConfidence :: Eq Confidence

confidenceLabel :: Confidence -> String
confidenceLabel = case _ of
  KnownGood -> "known-good"
  LikelyGood -> "likely-good"
  Unknown -> "unknown"
  KnownBad -> "known-bad"

-- | Classify a probed target `(os, nix-arch)` against the earned catalog.
-- | `KnownGood` entries have a real green install behind them (BlackStar for
-- | x86_64-linux 2026-07-23; the Mini for aarch64-darwin). Their near neighbours
-- | are `LikelyGood` (plausible, untested → override required).
classify :: { os :: String, arch :: String } -> Confidence
classify { os, arch } = case os, arch of
  "linux", "x86_64" -> KnownGood
  "darwin", "aarch64" -> KnownGood
  "darwin", "x86_64" -> LikelyGood
  "linux", "aarch64" -> LikelyGood
  _, _ -> Unknown

-- | Map a probed `uname -s` / `uname -m` pair to a Nix `system` double, or
-- | `Nothing` for a platform we don't recognise (uname's `arm64` ⇒ `aarch64`).
nixSystem :: String -> String -> Maybe String
nixSystem unameS unameM = case os, arch of
  Just o, Just a -> Just (a <> "-" <> o)
  _, _ -> Nothing
  where
  os = case unameS of
    "Linux" -> Just "linux"
    "Darwin" -> Just "darwin"
    _ -> Nothing
  arch = case unameM of
    "x86_64" -> Just "x86_64"
    "arm64" -> Just "aarch64"
    "aarch64" -> Just "aarch64"
    _ -> Nothing

-- | The login shell on the target — selects which rc files the toolchain-floor
-- | lines land in. Bash on Linux (BlackStar), Zsh on macOS (the Mini/MBP).
data Shell = Bash | Zsh

-- | "bring THIS target to par", declaratively: the flake ref that supplies the
-- | pins, the target's Nix `system` double, the package attrs to install, the
-- | nixpkgs-sourced extras (nix-direnv), and the login shell. The effectful edge
-- | probes the target (arch, /nix, shell) to fill this in; the plan is derived
-- | purely from it.
type ApplySpec =
  { flakeRef :: String
  , system :: String
  , pins :: Array String
  , nixpkgsPins :: Array String
  , shell :: Shell
  }

-- | One phase of the plan: a label and the ordered command-lines that enact it,
-- | to run ON the target (one shell per phase — the edge feeds `commands` to a
-- | single `bash` invocation, as blackstar-par.sh does per section).
type ApplyStep = { phase :: String, commands :: Array String }

-- | The 18 `quartermaster#packages` pins that are the toolchain floor (the
-- | par-spec's profile pins minus nix-direnv, which comes from nixpkgs).
parPins :: Array String
parPins =
  [ "cabal", "cargo", "erlang", "esbuild", "ffmpeg", "ghc", "go", "node"
  , "purescript-language-server", "purs", "purs-tidy", "python", "rebar3"
  , "rust-analyzer", "rustc", "spago", "stack", "tools"
  ]

-- | nix-direnv is nixpkgs-sourced (not an overlay pin), so it rides the
-- | `nixpkgsPins` list rather than `flakeRef#packages`.
nixDirenvPin :: String
nixDirenvPin = "nix-direnv"

-- | The one imperative act, guarded idempotent: install Determinate Nix only if
-- | /nix is absent, then confirm the daemon answers.
sourceDaemon :: String
sourceDaemon = ". /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"

-- | Idempotent per-pin install, matched against a ONE-SHOT profile snapshot
-- | (`$installed`, captured once per phase — see `applyPlan`). Grepping a
-- | here-string rather than piping `nix profile list` per pin avoids the
-- | broken-pipe SIGPIPE noise `grep -q` triggers by closing the pipe early, and
-- | is 19× fewer nix invocations. Skip if already pinned, else install.
installPin :: ApplySpec -> String -> String
installPin spec p =
  "grep -q 'packages\\." <> spec.system <> "\\." <> p <> "$' <<<\"$installed\""
    <> " && echo '  = " <> p <> " (pinned)'"
    <> " || { nix profile install '" <> spec.flakeRef <> "#packages." <> spec.system <> "." <> p <> "' && echo '  + " <> p <> "'; }"

installNixpkgsPin :: String -> String
installNixpkgsPin np =
  "grep -q '" <> np <> "' <<<\"$installed\""
    <> " && echo '  = " <> np <> " (pinned)'"
    <> " || { nix profile install 'nixpkgs#" <> np <> "' && echo '  + " <> np <> "'; }"

shellName :: Shell -> String
shellName = case _ of
  Bash -> "bash"
  Zsh -> "zsh"

-- | (rc file, login-profile file) the toolchain-floor lines append to.
rcFiles :: Shell -> { rc :: String, profile :: String }
rcFiles = case _ of
  Bash -> { rc: "~/.bashrc", profile: "~/.profile" }
  Zsh -> { rc: "~/.zshrc", profile: "~/.zprofile" }

-- | The shell-rc phase, idempotent: direnv hook + nix-profile PATH precedence in
-- | the interactive rc, PATH in the login profile, and the nix-direnv source in
-- | direnvrc. Each guarded by a grep so re-apply is a no-op.
rcCommands :: Shell -> Array String
rcCommands sh =
  let
    f = rcFiles sh
    hook = "eval \"$(direnv hook " <> shellName sh <> ")\""
    pathLine = "export PATH=\"$HOME/.nix-profile/bin:$PATH\""
  in
    [ "grep -q 'nix-profile/bin' " <> f.rc <> " 2>/dev/null"
        <> " && echo '  = " <> f.rc <> "'"
        <> " || { printf '\\n# nix toolchain floor\\n%s\\n%s\\n' '" <> hook <> "' '" <> pathLine <> "' >> " <> f.rc <> " && echo '  + " <> f.rc <> "'; }"
    , "grep -q 'nix-profile/bin' " <> f.profile <> " 2>/dev/null"
        <> " && echo '  = " <> f.profile <> "'"
        <> " || { printf '\\n%s\\n' '" <> pathLine <> "' >> " <> f.profile <> " && echo '  + " <> f.profile <> "'; }"
    , "mkdir -p ~/.config/direnv"
    , "[ -f ~/.config/direnv/direnvrc ]"
        <> " && echo '  = direnvrc'"
        <> " || { echo 'source \"$HOME/.nix-profile/share/nix-direnv/direnvrc\"' > ~/.config/direnv/direnvrc && echo '  + direnvrc'; }"
    ]

-- | The verify-ready phase — the same green gate blackstar-par.sh's postflight
-- | asserted: pin count + a tool-version probe per language.
verifyCommands :: ApplySpec -> Array String
verifyCommands spec =
  let
    b = "$HOME/.nix-profile/bin"
    ver name bin flag = "echo '  " <> name <> ": '$(" <> b <> "/" <> bin <> " " <> flag <> " 2>/dev/null || echo MISSING)"
    want = show (A.length spec.pins + A.length spec.nixpkgsPins)
  in
    [ sourceDaemon
    , "echo '  pins: '$(nix profile list | grep -c '^Name:')' (want " <> want <> ")'"
    , ver "purs" "purs" "--version"
    , ver "node" "node" "--version"
    , ver "go" "go" "version"
    , ver "python" "python3" "--version"
    , ver "rustc" "rustc" "--version"
    , ver "ghc" "ghc" "--version"
    ]

-- | Derive the four-phase apply plan from a spec. Pure — the faithful
-- | codification of the proven blackstar-par.sh sequence.
applyPlan :: ApplySpec -> Array ApplyStep
applyPlan spec =
  [ { phase: "ignition"
    , commands:
        [ "if [ -e /nix ]; then echo '  = nix present'; else curl --proto =https --tlsv1.2 -fsSL https://install.determinate.systems/nix | sh -s -- install --determinate --no-confirm; fi"
        , sourceDaemon <> " && nix --version"
        ]
    }
  , { phase: "apply"
    , commands:
        [ sourceDaemon
        , "export NIX_CONFIG='experimental-features = nix-command flakes'"
        , "installed=\"$(nix profile list 2>/dev/null || true)\""
        ]
          <> map (installPin spec) spec.pins
          <> map installNixpkgsPin spec.nixpkgsPins
    }
  , { phase: "shell-rc", commands: rcCommands spec.shell }
  , { phase: "verify", commands: verifyCommands spec }
  ]

-- | The shell command that ENACTS one phase on a resolved `Target` — the phase's
-- | command-lines joined into one script, ssh-wrapped when the host is remote,
-- | run locally otherwise. Pure and total, the single source the CLI both
-- | DISPLAYS (dry-run) and RUNS — what you see is exactly what executes, the same
-- | discipline as Bosun's `applyScript` and Quartermaster.Build's `buildInvocation`.
applyInvocation :: Target -> ApplyStep -> String
applyInvocation target step =
  case target.exec of
    RemoteSsh dest -> "ssh " <> unSshDest dest <> " bash -s <<'QMEOF'\n" <> body <> "\nQMEOF"
    LocalExec -> body
  where
  body = intercalate "\n" step.commands

-- | Render the whole plan for the dry-run: phases with their command-lines,
-- | grouped and labelled the way the postflight log reads.
renderPlan :: Array ApplyStep -> String
renderPlan = intercalate "\n\n" <<< map renderStep
  where
  renderStep s = "### " <> s.phase <> "\n" <> intercalate "\n" (map ("  " <> _) s.commands)
