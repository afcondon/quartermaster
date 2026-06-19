-- | The effectful host-capability PROBE edge. Interprets a pure `ProbeSpec` by
-- | running a synchronous shell check (the no-Aff seam — `command -v` / `test`,
-- | straight-line, no callbacks) and reports the outcome back to the pure
-- | verdict logic. v1 probes the LOCAL host; a remote (ssh-wrapped) probe via
-- | Bosun's `Target` is the immediate next step (the seam shares host identity).
module Quartermaster.CLI.Probe (probeRequirement) where

import Prelude

import Bosun.Atoms (unAbsPath)
import Data.Maybe (Maybe(..))
import Data.String (Pattern(..), Replacement(..))
import Data.String as String
import Effect (Effect)
import Effect.Uncurried (EffectFn1, runEffectFn1)
import Quartermaster.Runtime (ProbeSpec(..), probeSpec)
import Quartermaster.Verify (ProbeOutcome, Requirement)

-- run `/bin/sh -c <cmd>`; { ok: exit 0, out: trimmed stdout }
foreign import shProbeImpl :: EffectFn1 String { ok :: Boolean, out :: String }

sh :: String -> Effect { ok :: Boolean, out :: String }
sh = runEffectFn1 shProbeImpl

probeRequirement :: Requirement -> Effect ProbeOutcome
probeRequirement req = do
  rt <- probeRuntime (probeSpec req.runtime)
  cwdOk <- case req.cwd of
    Nothing -> pure true
    Just p -> _.ok <$> sh ("test -d " <> shQuote (unAbsPath p))
  pure { requirement: req, present: rt.present, version: rt.version, cwdOk }

probeRuntime :: ProbeSpec -> Effect { present :: Boolean, version :: Maybe String }
probeRuntime = case _ of
  CommandOnPath name -> do
    r <- sh ("command -v " <> shQuote name)
    ver <- if r.ok then bestEffortVersion name else pure Nothing
    pure { present: r.ok, version: ver }
  FileExecutable path -> do
    r <- sh ("test -x " <> shQuote path)
    pure { present: r.ok, version: Nothing }
  EngineAny -> do
    r <- sh "command -v docker || command -v podman || command -v nerdctl"
    pure { present: r.ok, version: Nothing }
  NoProbe _ -> pure { present: false, version: Nothing }

bestEffortVersion :: String -> Effect (Maybe String)
bestEffortVersion name = do
  r <- sh (shQuote name <> " --version 2>/dev/null | head -1")
  pure (if r.ok && r.out /= "" then Just r.out else Nothing)

-- minimal POSIX single-quote escaping for a shell argument
shQuote :: String -> String
shQuote s = "'" <> String.replaceAll (Pattern "'") (Replacement "'\\''") s <> "'"
