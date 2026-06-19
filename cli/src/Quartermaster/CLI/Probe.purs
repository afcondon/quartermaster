-- | The effectful host-capability PROBE edge. Interprets a pure `ProbeSpec` by
-- | running a synchronous shell check (`command -v` / `test`, the no-Aff seam),
-- | on the service's OWN host: a local host runs the check directly; a remote one
-- | ssh-wraps it, reusing Bosun's `Target` (the seam shares host identity). So a
-- | mixed deployment verifies each service where it actually runs — laptop
-- | services locally, MacMini services over ssh — with no `--target` juggling.
-- |
-- | The remote shell is non-interactive (it does not source the login profile),
-- | so the target's `envPrefix` (e.g. the MacMini's PATH covering homebrew /
-- | Docker Desktop) is prepended exactly as Bosun does for its remote commands —
-- | otherwise `command -v julia` would miss a perfectly-installed julia.
module Quartermaster.CLI.Probe (probeRequirement) where

import Prelude

import Bosun.Atoms (unAbsPath)
import Bosun.Target (ExecLoc(..), Target, TargetMap, resolveTarget, unSshDest)
import Data.Foldable (foldMap)
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Uncurried (EffectFn1, runEffectFn1)
import Quartermaster.Runtime (ProbeSpec(..), probeSpec)
import Quartermaster.Verify (ProbeOutcome, Requirement)

-- run `/bin/sh -c <cmd>`; { ok: exit 0, out: trimmed stdout }
foreign import shProbeImpl :: EffectFn1 String { ok :: Boolean, out :: String }

sh :: String -> Effect { ok :: Boolean, out :: String }
sh = runEffectFn1 shProbeImpl

probeRequirement :: TargetMap -> Requirement -> Effect ProbeOutcome
probeRequirement tmap req = do
  let target = resolveTarget tmap req.host
  rt <- probeRuntime target (probeSpec req.runtime)
  cwdOk <- case req.cwd of
    Nothing -> pure true
    Just p -> _.ok <$> runOn target ("test -d " <> unAbsPath p)
  pure { requirement: req, present: rt.present, version: rt.version, cwdOk }

probeRuntime :: Target -> ProbeSpec -> Effect { present :: Boolean, version :: Maybe String }
probeRuntime target = case _ of
  CommandOnPath name -> do
    r <- runOn target ("command -v " <> name)
    ver <- if r.ok then bestEffortVersion target name else pure Nothing
    pure { present: r.ok, version: ver }
  FileExecutable path -> do
    r <- runOn target ("test -x " <> path)
    pure { present: r.ok, version: Nothing }
  EngineAny -> do
    r <- runOn target "command -v docker || command -v podman || command -v nerdctl"
    pure { present: r.ok, version: Nothing }
  NoProbe _ -> pure { present: false, version: Nothing }

bestEffortVersion :: Target -> String -> Effect (Maybe String)
bestEffortVersion target name = do
  r <- runOn target (name <> " --version 2>/dev/null | head -1")
  pure (if r.ok && r.out /= "" then Just r.out else Nothing)

-- | Run a probe command on the resolved target: prepend the target's env prefix
-- | (PATH etc. for a non-interactive remote shell), then ssh-wrap if remote. The
-- | probe commands use bare tokens (binary names, absolute paths) with no inner
-- | single quotes, so single-quoting the whole line for ssh is safe.
runOn :: Target -> String -> Effect { ok :: Boolean, out :: String }
runOn target inner = sh (wrap target (envExports target.envPrefix <> inner))

wrap :: Target -> String -> String
wrap target line = case target.exec of
  RemoteSsh dest -> "ssh " <> unSshDest dest <> " '" <> line <> "'"
  LocalExec -> line

envExports :: Array (Tuple String String) -> String
envExports = foldMap \(Tuple k v) -> "export " <> k <> "=" <> v <> " && "
