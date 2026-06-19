-- | The build/ship half of the seam (`quartermaster build`) — the thing Bosun's
-- | `# MANUAL: build-once-ship` advisory points ACROSS the seam at. A service
-- | declared with a `build:` context (a `Container` whose source is a
-- | `BuildContext`, not a prebuilt `ImageRef`) is the build-per-host
-- | anti-pattern; Quartermaster builds it ONCE into a pinned image and ships it
-- | to the registry, so every host runs the same bytes (ARTIFACTS.md
-- | build-once-ship). The PLAN is pure (the command strings), like Bosun's
-- | `applyScript`; running it is the effectful CLI edge (and gated, since a push
-- | is outward).
module Quartermaster.Build
  ( BuildStep
  , buildPlan
  , buildShellLine
  , buildInvocation
  ) where

import Prelude

import Bosun.Atoms (Host, unAbsPath)
import Bosun.Executor (BuildContext(..), ContainerSpec(..), Executor(..))
import Bosun.Service (ServiceInstance)
import Bosun.Target (ExecLoc(..), Target, unSshDest)
import Data.Array as A
import Data.Either (Either(..))
import Data.Foldable (foldMap, intercalate)
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Tuple (Tuple(..))

-- | One service to build+ship: the host it builds ON (the build target — its
-- | context lives there and, for a host-local registry, so must the push), its
-- | source context, the target image ref, and the ordered commands that realise
-- | it (`docker build … -t <image>` then `docker push <image>`). All-string, so
-- | it crosses to the exec edge / a Go twin with no decoding (the applyScript
-- | discipline).
type BuildStep =
  { service :: String
  , host :: Maybe Host
  , context :: String
  , image :: String
  , commands :: Array String
  }

-- | Derive the build plan: one `BuildStep` per service that builds from source.
-- | A service already pinned to a prebuilt `ImageRef` is skipped (nothing to
-- | build — it IS the shipped artifact). `registry`/`pin` parameterise the target
-- | tag (`<registry>/<service>:<pin>`), so the same plan ships to a local
-- | registry (`localhost:5001`) or a remote one.
buildPlan :: String -> String -> Array ServiceInstance -> Array BuildStep
buildPlan registry pin = A.mapMaybe step
  where
  step si = case si.executor of
    Container (ContainerSpec cs) -> case cs.source of
      Right (BuildContext bc) ->
        let
          image = registry <> "/" <> si.localName <> ":" <> pin
          -- compose resolves `dockerfile` RELATIVE TO `context`; raw `docker
          -- build -f` resolves it relative to the CWD. We run from the build
          -- host's workdir with a context relative to it, so join the two —
          -- otherwise `-f docker/Dockerfile` looks under the workdir and misses.
          dockerf = case bc.dockerfile of
            Just f -> " -f " <> bc.context <> "/" <> f
            Nothing -> ""
        in
          Just
            { service: si.localName
            , host: si.host
            , context: bc.context
            , image
            , commands:
                [ "docker build " <> bc.context <> dockerf <> " -t " <> image
                , "docker push " <> image
                ]
            }
      Left _ -> Nothing -- already a prebuilt image — nothing to build
    _ -> Nothing

-- | The single shell line that ENACTS a build step, derived from the same
-- | `commands` the dry-run prints (one source of truth — display and execution
-- | never drift). `push = true` chains build `&& push` so the push only happens
-- | on a clean build; `push = false` is build-only (the `--no-push` safe step).
-- | Pure: the cwd/env/ssh wrapping is the CLI edge's job (Quartermaster.CLI.Build),
-- | exactly as Bosun keeps `applyScript` pure and wraps at the exec edge.
buildShellLine :: Boolean -> BuildStep -> String
buildShellLine push step
  | push = intercalate " && " step.commands
  | otherwise = fromMaybe "" (A.head step.commands)

-- | The full shell command that ENACTS a build step on a resolved `Target` —
-- | pure and total, the single source the CLI both DISPLAYS and RUNS (so what
-- | you see is exactly what executes). The build runs in the target's `workdir`
-- | (the context is relative to it), with `envPrefix` prepended (a remote ssh
-- | shell needs `PATH` for `docker`), ssh-wrapped when the host is remote —
-- | the same shape Bosun's `applyScript` renders for container ops, kept here in
-- | the pure core so the node and backend-go builds emit byte-identical strings.
buildInvocation :: Target -> Boolean -> BuildStep -> String
buildInvocation target push step =
  wrap target (cdWorkdir target <> envExports target.envPrefix <> buildShellLine push step)
  where
  cdWorkdir t = maybe "" (\w -> "cd " <> unAbsPath w <> " && ") t.workdir
  wrap t line = case t.exec of
    RemoteSsh dest -> "ssh " <> unSshDest dest <> " '" <> line <> "'"
    LocalExec -> line
  envExports = foldMap \(Tuple k v) -> "export " <> k <> "=" <> v <> " && "
