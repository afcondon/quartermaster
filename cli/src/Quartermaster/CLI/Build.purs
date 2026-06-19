-- | The effectful BUILD/SHIP edge — runs a `BuildStep`'s `docker build`
-- | [`&& docker push`] for real. The command LINE is pure
-- | (`Quartermaster.Build.buildInvocation`, the same string the CLI displays and
-- | the dry-run prints); this module only streams it.
-- |
-- | Unlike the verify PROBE (a quick captured `command -v`), a build is long and
-- | chatty, so the foreign INHERITS stdio (docker progress streams straight to
-- | the terminal) and has no timeout. The push is genuinely outward — the CLI
-- | gates it behind an explicit verb, not a default-on side effect.
module Quartermaster.CLI.Build (runBuildStep) where

import Prelude

import Bosun.Target (Target)
import Effect (Effect)
import Effect.Uncurried (EffectFn1, runEffectFn1)
import Quartermaster.Build (BuildStep, buildInvocation)

-- run `/bin/sh -c <cmd>` with INHERITED stdio (streaming, no capture, no
-- timeout); { ok: exit 0 }. The build/ship counterpart to Probe's captured sh.
foreign import runStreamImpl :: EffectFn1 String { ok :: Boolean }

-- | Build (and optionally push) one step on its resolved host. Returns whether
-- | the command chain exited cleanly. The caller resolves the `Target` (so it can
-- | display the exact invocation first via `buildInvocation`).
runBuildStep :: Target -> Boolean -> BuildStep -> Effect Boolean
runBuildStep target push step =
  _.ok <$> runEffectFn1 runStreamImpl (buildInvocation target push step)
