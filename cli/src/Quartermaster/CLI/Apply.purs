-- | The effectful edge of `quartermaster apply` — the runner that turns the pure
-- | plan (Quartermaster.Apply) into a provisioned host. Three moves, in order:
-- |
-- |   1. PROBE the target over ssh (uname → Nix system, /nix presence, login
-- |      shell), reusing the same no-Aff sync-exec seam as verify's probe.
-- |   2. MISU GATE: classify the probed platform against the earned catalog.
-- |      Only known-good provisions silently; anything else needs --force, and
-- |      the override NAMES the confidence it's overriding.
-- |   3. RUN each plan phase, streaming its output live (Nix install + downloads
-- |      are long — a buffered/timed exec would truncate), stopping on failure.
-- |
-- | This is the base path the fleet proved on BlackStar: the target self-
-- | substitutes the par pins from a public flake ref. `applyInvocation` (the
-- | ssh/local wrapping) lives in the pure core so display and execution never
-- | drift; this module just enacts it.
module Quartermaster.CLI.Apply
  ( ApplyOpts
  , mkApplyTarget
  , runApplyLive
  ) where

import Prelude

import Bosun.Target (ExecLoc(..), Target, localTarget, mkSshDest, unSshDest)
import Data.Array as A
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String as String
import Data.String.Pattern (Pattern(..))
import Effect (Effect)
import Effect.Console (log)
import Effect.Uncurried (EffectFn1, runEffectFn1)
import Quartermaster.Apply (ApplyStep, Confidence(..), Shell(..), applyInvocation, applyPlan, classify, confidenceLabel, nixDirenvPin, nixSystem, parPins)

-- | Run a probe synchronously, capture trimmed stdout ({ ok: exit 0, out }).
foreign import captureImpl :: EffectFn1 String { ok :: Boolean, out :: String }

-- | Run a long phase with LIVE streamed stdio (no timeout) → exit code.
foreign import streamImpl :: EffectFn1 String Int

type ApplyOpts = { force :: Boolean, flake :: String, shellOverride :: Maybe Shell }

-- | Build the enactment Target for a raw destination: `local`/`localhost` runs
-- | locally, anything else is an ssh dest. Only `exec` matters to
-- | `applyInvocation`; the rest rides `localTarget`'s defaults.
mkApplyTarget :: String -> Target
mkApplyTarget dest
  | dest == "local" || dest == "localhost" = localTarget
  | otherwise = localTarget { exec = RemoteSsh (mkSshDest dest), address = dest }

-- | Single-command ssh wrap for the probes (phases carry their own wrap via
-- | `applyInvocation`).
wrapProbe :: Target -> String -> String
wrapProbe target cmd = case target.exec of
  RemoteSsh dest -> "ssh " <> unSshDest dest <> " '" <> cmd <> "'"
  LocalExec -> cmd

capture :: Target -> String -> Effect { ok :: Boolean, out :: String }
capture target cmd = runEffectFn1 captureImpl (wrapProbe target cmd)

shellStr :: Shell -> String
shellStr = case _ of
  Bash -> "bash"
  Zsh -> "zsh"

-- | Probe the target: `uname -s`/`-m` → Nix system, /nix presence, and the login
-- | shell (unless overridden). Left on unreachable/unrecognised.
detect
  :: Target
  -> Maybe Shell
  -> Effect (Either String { os :: String, arch :: String, system :: String, shell :: Shell, nixPresent :: Boolean })
detect target shellOverride = do
  u <- capture target "uname -sm"
  if not u.ok then pure (Left "could not probe target (uname failed — reachable over ssh?)")
  else do
    let
      parts = String.split (Pattern " ") u.out
      os = fromMaybe "" (A.head parts)
      arch = fromMaybe "" (A.index parts 1)
    case nixSystem os arch of
      Nothing -> pure (Left ("unrecognised platform: uname -sm = '" <> u.out <> "'"))
      Just system -> do
        nx <- capture target "test -e /nix && echo yes || echo no"
        shell <- case shellOverride of
          Just s -> pure s
          Nothing -> do
            s <- capture target "case \"$SHELL\" in *zsh) echo zsh;; *) echo bash;; esac"
            pure (if String.trim s.out == "zsh" then Zsh else Bash)
        pure (Right { os: normOs os, arch: normArch arch, system, shell, nixPresent: String.trim nx.out == "yes" })
  where
  -- classify wants the Nix-normalised (os, arch), matching nixSystem's mapping
  normOs = case _ of
    "Linux" -> "linux"
    "Darwin" -> "darwin"
    o -> o
  normArch = case _ of
    "arm64" -> "aarch64"
    a -> a

-- | Probe → gate → run. The live counterpart to the dry-run plan printer.
runApplyLive :: ApplyOpts -> Target -> String -> Effect Unit
runApplyLive opts target label = do
  log ("quartermaster — apply " <> label)
  det <- detect target opts.shellOverride
  case det of
    Left err -> log ("  ✗ " <> err)
    Right d -> do
      let conf = classify { os: d.os, arch: d.arch }
      log
        ( "  target: " <> d.system <> " (" <> confidenceLabel conf <> ")"
            <> "  nix: " <> (if d.nixPresent then "present" else "absent")
            <> "  shell: " <> shellStr d.shell
        )
      if conf /= KnownGood && not opts.force then do
        log ("  ✗ target is " <> confidenceLabel conf <> ", not known-good — refusing without --force.")
        log "    re-run with --force to provision anyway (a green result promotes it to known-good)."
      else do
        when (conf /= KnownGood) (log ("  ⚠ override: " <> confidenceLabel conf <> " target, proceeding under --force"))
        let
          spec =
            { flakeRef: opts.flake
            , system: d.system
            , pins: parPins
            , nixpkgsPins: [ nixDirenvPin ]
            , shell: d.shell
            }
        ok <- runPhases target (applyPlan spec)
        if ok then log "\n  ✓ apply complete — see the verify block above (green ⇒ promote this class to known-good)."
        else log "\n  ✗ apply stopped on a failed phase."

-- | Run phases in order, streaming each; stop on the first non-zero exit.
runPhases :: Target -> Array ApplyStep -> Effect Boolean
runPhases target = go
  where
  go steps = case A.uncons steps of
    Nothing -> pure true
    Just { head: s, tail: rest } -> do
      log ("\n################ " <> s.phase <> " ################")
      code <- runEffectFn1 streamImpl (applyInvocation target s)
      if code == 0 then go rest
      else do
        log ("  ✗ phase '" <> s.phase <> "' exited " <> show code)
        pure false
