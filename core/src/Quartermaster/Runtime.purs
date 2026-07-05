-- | The RUNTIMES a host must provide for a deployment's services to launch — the
-- | vocabulary of Quartermaster's host-capability pre-flight (`quartermaster
-- | verify`). Each `Runtime` carries how to PROVE it present on a host (a
-- | `ProbeSpec`): a toolchain is "binary on PATH", a prebuilt artifact is "this
-- | file exists + is executable", a containerised service is "a container engine
-- | is present". Derived purely from a service's `Executor` (the launch command
-- | head), so the whole derivation rides backend-go like Bosun's pure core.
module Quartermaster.Runtime
  ( Runtime(..)
  , runtimeLabel
  , ProbeSpec(..)
  , probeSpec
  , runtimeOfExecutor
  , runtimeOfCommand
  ) where

import Prelude

import Bosun.Executor (Executor)
import Bosun.Executor as Executor
import Bosun.Publish (PublishChannel(..))
import Data.Array as A
import Data.Maybe (Maybe(..))
import Data.String (Pattern(..))
import Data.String as String

-- | A runtime a host may need to provide. `BinaryAt` is a prebuilt artifact at a
-- | concrete path (Go/Rust output, a shipped binary); `OnPath` is a bare command
-- | expected on PATH; `Container` is any container engine; `Unknown` keeps the
-- | command head so the report can name what it couldn't classify (never a
-- | silent pass).
data Runtime
  = Node
  | Python
  | Julia
  | Erlang
  | GoToolchain
  | RustToolchain
  | Container
  | Wrangler           -- Cloudflare Pages publish via `npx wrangler` (the StaticCDN publish tool)
  | OnPath String      -- a bare command expected on PATH (e.g. `static-httpd`)
  | BinaryAt String    -- a prebuilt executable at this path (`./srv`, `/usr/local/bin/x`)
  | Unknown String

derive instance Eq Runtime

runtimeLabel :: Runtime -> String
runtimeLabel = case _ of
  Node -> "node"
  Python -> "python3"
  Julia -> "julia"
  Erlang -> "erlang"
  GoToolchain -> "go"
  RustToolchain -> "cargo"
  Container -> "container engine"
  Wrangler -> "wrangler (npx)"
  OnPath c -> c
  BinaryAt p -> p
  Unknown c -> "unknown (" <> c <> ")"

-- | How to PROVE a runtime present on a host. The effectful probe edge
-- | (`Quartermaster.CLI.Probe`) interprets these; the spec itself is pure.
data ProbeSpec
  = CommandOnPath String   -- `command -v <name>` exits 0
  | FileExecutable String  -- `test -x <path>`
  | EngineAny              -- any of docker|podman|nerdctl on PATH
  | NoProbe String         -- nothing to check (with a note why)

derive instance Eq ProbeSpec

probeSpec :: Runtime -> ProbeSpec
probeSpec = case _ of
  Node -> CommandOnPath "node"
  Python -> CommandOnPath "python3"
  Julia -> CommandOnPath "julia"
  Erlang -> CommandOnPath "erl"
  GoToolchain -> CommandOnPath "go"
  RustToolchain -> CommandOnPath "cargo"
  Container -> EngineAny
  -- "can this host publish?" = can it run `npx wrangler` — checks the runner is
  -- present (node/npx), not CF auth (a credentials check, future work — cf #238's
  -- DOCKER_CONFIG-style host prep, the peer of `docker login` for build-once-ship).
  Wrangler -> CommandOnPath "npx"
  OnPath c -> CommandOnPath c
  BinaryAt p -> FileExecutable p
  Unknown c -> NoProbe ("cannot classify launch command head: " <> c)

-- | Derive the runtime a service needs from its `Executor`. A `Container` needs a
-- | container engine; a `Process` is classified by its command. The other
-- | executors (CDN/systemd/launchd/remote/unmanaged) are not Quartermaster's to
-- | provision a host for, so they read `Unknown` with the mechanism named.
runtimeOfExecutor :: Executor -> Runtime
runtimeOfExecutor = case _ of
  Executor.Process pr -> runtimeOfCommand pr.command
  Executor.Container _ -> Container
  -- A StaticCDN service isn't "launched on a host" — it's published to a CDN, so
  -- verify's question becomes "can this host PUBLISH?": the publish tool for the
  -- channel. wrangler for CF-Pages-wrangler; git for the git-push channels.
  Executor.StaticCDN cdn -> case cdn.publish of
    CloudflarePagesWrangler _ -> Wrangler
    CloudflarePagesGit _ -> OnPath "git"
    GitHubPagesRepoDir _ -> OnPath "git"
  Executor.SystemdUnit _ -> Unknown "systemd"
  Executor.LaunchdJob _ -> Unknown "launchd"
  Executor.Remote _ -> Unknown "remote"
  Executor.Unmanaged s -> runtimeOfCommand s

-- | Classify a launch command by its HEAD token, after skipping any leading
-- | `VAR=val` env assignments (the `ATLAS_PORT=3210 julia …` / `ERL_LIBS=… erl …`
-- | shape). A path-like head (`/x`, `./x`) is a prebuilt binary; a known
-- | interpreter maps to its runtime; any other bare word is expected on PATH.
runtimeOfCommand :: String -> Runtime
runtimeOfCommand raw = case A.head (dropAssignments (tokens raw)) of
  Nothing -> Unknown ""
  Just head -> classify head
  where
  tokens = A.filter (_ /= "") <<< String.split (Pattern " ") <<< String.trim
  -- a leading `KEY=val` is an env assignment, not the command (no leading `/`,
  -- contains `=` before any `/`).
  dropAssignments = A.dropWhile isAssignment
  isAssignment t = String.contains (Pattern "=") t && not (isPathLike t)
  isPathLike t = isJustPrefix "/" t || isJustPrefix "./" t || isJustPrefix "../" t
  isJustPrefix p t = case String.stripPrefix (Pattern p) t of
    Just _ -> true
    Nothing -> false
  classify head
    | isPathLike head = BinaryAt head
    | otherwise = case head of
        "node" -> Node
        "npx" -> Node
        "npm" -> Node
        "python3" -> Python
        "python" -> Python
        "julia" -> Julia
        "erl" -> Erlang
        "rebar3" -> Erlang
        "escript" -> Erlang
        "elixir" -> Erlang
        "go" -> GoToolchain
        "cargo" -> RustToolchain
        "docker" -> Container
        "podman" -> Container
        "nerdctl" -> Container
        other -> OnPath other
