-- | The effectful edge of `quartermaster exec` — resolve the flake ref, render
-- | the pure script (Quartermaster.Exec), run it live, and propagate the exit
-- | code. Three moves:
-- |
-- |   1. RESOLVE the flake dev-shell: an explicit `--flake REF` wins; else read
-- |      `.envrc` in the cwd and auto-detect `use flake <ref>`; else no flake
-- |      (bare passthrough against the profile toolchain).
-- |   2. RENDER the script purely (`execScript`) — the plan the core owns.
-- |   3. RUN it with LIVE inherited stdio (no timeout — a build streams megabytes
-- |      over minutes), then set the process exit code to the command's, so
-- |      `quartermaster exec -- spago build` behaves exactly like `spago build`.
-- |
-- | Deliberately quiet: no header, no chatter — the wrapped command's stdout/
-- | stderr passes straight through, which is what an agent build wrapper needs.
module Quartermaster.CLI.Exec
  ( runExecLive
  ) where

import Prelude

import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Console (log)
import Effect.Uncurried (EffectFn1, runEffectFn1)
import Quartermaster.Exec (execScript, parseFlakeRef)

-- | Read a file at the edge, never throwing: `{ found, contents }` (found = false
-- | when the file is absent — a repo without an `.envrc` just has no flake).
foreign import readFileImpl :: EffectFn1 String { found :: Boolean, contents :: String }

-- | Run the script with LIVE streamed stdio (no timeout) → exit code. `bash -c`
-- | so the rendered script (source-daemon preamble + `exec`) runs in a real shell.
-- | Same seam as Quartermaster.CLI.Apply's streamImpl.
foreign import streamImpl :: EffectFn1 String Int

-- | Set the Node process exit code (deferred, so streamed output flushes) — the
-- | wrapped command's status becomes `quartermaster`'s.
foreign import setExitCode :: EffectFn1 Int Unit

-- | Resolve the flake ref (explicit `--flake`, else `.envrc` auto-detect, else
-- | none), render, and — unless `dryRun` — run it and propagate the exit code.
-- | `dryRun` prints the exact script `exec` would run (the pure `execScript`) and
-- | exits 0 without running it: the "show me what exec would do" surface, and the
-- | conformance case that keeps exec honest to the applyScript discipline like the
-- | other verbs. Flake resolution is identical in both modes (the same `.envrc`
-- | read), so the dry-run text matches what a live run would enact.
runExecLive :: Boolean -> Maybe String -> Array String -> Effect Unit
runExecLive dryRun explicitFlake command = do
  flakeRef <- case explicitFlake of
    Just ref -> pure (Just ref)
    Nothing -> do
      r <- runEffectFn1 readFileImpl ".envrc"
      pure (if r.found then parseFlakeRef r.contents else Nothing)
  let script = execScript { flakeRef, command }
  if dryRun then log script
  else do
    code <- runEffectFn1 streamImpl script
    runEffectFn1 setExitCode code
