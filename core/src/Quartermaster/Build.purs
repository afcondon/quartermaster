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
  ) where

import Prelude

import Bosun.Executor (BuildContext(..), ContainerSpec(..), Executor(..))
import Bosun.Service (ServiceInstance)
import Data.Array as A
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))

-- | One service to build+ship: its source context, the target image ref, and the
-- | ordered commands that realise it (`docker build … -t <image>` then
-- | `docker push <image>`). All-string, so it crosses to the exec edge / a Go
-- | twin with no decoding (the applyScript discipline).
type BuildStep =
  { service :: String
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
          dockerf = case bc.dockerfile of
            Just f -> " -f " <> f
            Nothing -> ""
        in
          Just
            { service: si.localName
            , context: bc.context
            , image
            , commands:
                [ "docker build " <> bc.context <> dockerf <> " -t " <> image
                , "docker push " <> image
                ]
            }
      Left _ -> Nothing -- already a prebuilt image — nothing to build
    _ -> Nothing
