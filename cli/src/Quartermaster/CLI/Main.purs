-- | The `quartermaster` CLI entrypoint.
-- |
-- |   quartermaster verify <compose.yml> <registry.json>
-- |     ingest the SAME deployment sources Bosun reads → derive each service's
-- |     host-capability requirement → probe the (local) host → readiness report.
-- |     The host-readiness half of the Bosun⇄Quartermaster seam.
-- |
-- |   quartermaster build [--dry-run] [--registry R] [--pin P] <compose> <registry>
-- |     the build/ship half: for each service that builds from source, the
-- |     docker build+push plan that produces the pinned image Bosun then runs
-- |     (build-once-ship). Dry-run for now — a live push is outward, gated like
-- |     Bosun's apply was.
module Quartermaster.CLI.Main where

import Prelude

import Bosun.Adapters.Compose (ingestCompose)
import Bosun.Adapters.Registry (ingestRegistry)
import Data.Array as A
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Traversable (traverse)
import Effect (Effect)
import Effect.Console (log)
import Quartermaster.Build (buildPlan)
import Quartermaster.CLI.IO (argv, readJsonFile, readYamlFile)
import Quartermaster.CLI.Probe (probeRequirement)
import Quartermaster.Report (renderBuild, renderVerify)
import Quartermaster.Verify (requirementsOf, verdictOf)

main :: Effect Unit
main = do
  raw <- argv
  let
    rf = takeFlag "--registry" raw
    pf = takeFlag "--pin" rf.rest
    args = A.filter (_ /= "--dry-run") pf.rest
    registry = fromMaybe "localhost:5001" rf.value
    pin = fromMaybe "latest" pf.value
  case args of
    [ "verify", composePath, registryPath ] -> runVerify composePath registryPath
    [ "build", composePath, registryPath ] -> runBuild registry pin composePath registryPath
    _ -> log usage

usage :: String
usage =
  "quartermaster — the provisioning companion to bosun\n\n"
    <> "  quartermaster verify <compose.yml> <registry.json>\n"
    <> "      can THIS host launch each declared service's runtime? (host pre-flight)\n\n"
    <> "  quartermaster build [--registry R] [--pin P] <compose.yml> <registry.json>\n"
    <> "      build+ship plan for services that build from source (build-once-ship; dry-run)"

runVerify :: String -> String -> Effect Unit
runVerify composePath registryPath = do
  composeJson <- readYamlFile composePath
  registryJson <- readJsonFile registryPath
  let
    insts = ingestCompose composeJson <> ingestRegistry registryJson
    reqs = requirementsOf insts
  log ("quartermaster — verify " <> composePath <> " + " <> registryPath)
  log ""
  outcomes <- traverse probeRequirement reqs
  log (renderVerify (map verdictOf outcomes))

runBuild :: String -> String -> String -> String -> Effect Unit
runBuild registry pin composePath registryPath = do
  composeJson <- readYamlFile composePath
  registryJson <- readJsonFile registryPath
  let
    insts = ingestCompose composeJson <> ingestRegistry registryJson
    steps = buildPlan registry pin insts
  log ("quartermaster — build --dry-run " <> composePath <> " + " <> registryPath <> "  (registry " <> registry <> ", pin " <> pin <> ")")
  log ""
  log (renderBuild steps)
  log ""
  log "(dry-run: the plan only. A live `docker build`/`push` is a deliberate next step — a push is outward.)"

-- | Pull an optional `<name> <value>` flag out of the args wherever it appears.
takeFlag :: String -> Array String -> { value :: Maybe String, rest :: Array String }
takeFlag name args = case A.findIndex (_ == name) args of
  Just i
    | Just v <- A.index args (i + 1) ->
        { value: Just v, rest: fromMaybe args (A.deleteAt i args >>= A.deleteAt i) }
  _ -> { value: Nothing, rest: args }
