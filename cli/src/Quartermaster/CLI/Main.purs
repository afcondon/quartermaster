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
import Bosun.Target (defaultTargets, isRemote, resolveTarget)
import Data.Array as A
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Traversable (traverse)
import Effect (Effect)
import Effect.Console (log)
import Quartermaster.Build (buildInvocation, buildPlan)
import Quartermaster.CLI.Build (runBuildStep)
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
    dr = takeBool "--dry-run" pf.rest
    np = takeBool "--no-push" dr.rest
    args = np.rest
    registry = fromMaybe "localhost:5001" rf.value
    pin = fromMaybe "latest" pf.value
  case args of
    [ "verify", composePath, registryPath ] -> runVerify composePath registryPath
    [ "build", composePath, registryPath ] ->
      runBuild { registry, pin, dryRun: dr.found, push: not np.found } composePath registryPath
    _ -> log usage

usage :: String
usage =
  "quartermaster — the provisioning companion to bosun\n\n"
    <> "  quartermaster verify <compose.yml> <registry.json>\n"
    <> "      can THIS host launch each declared service's runtime? (host pre-flight)\n\n"
    <> "  quartermaster build [--registry R] [--pin P] [--dry-run] [--no-push] <compose.yml> <registry.json>\n"
    <> "      build + ship the services that build from source (build-once-ship), on their\n"
    <> "      build host (ssh-wrapped for a remote target). --dry-run prints the plan only;\n"
    <> "      --no-push builds without the (outward) push."

runVerify :: String -> String -> Effect Unit
runVerify composePath registryPath = do
  composeJson <- readYamlFile composePath
  registryJson <- readJsonFile registryPath
  let
    insts = ingestCompose composeJson <> ingestRegistry registryJson
    reqs = requirementsOf insts
  log ("quartermaster — verify " <> composePath <> " + " <> registryPath)
  log ""
  outcomes <- traverse (probeRequirement defaultTargets) reqs
  log (renderVerify (map verdictOf outcomes))

runBuild :: { registry :: String, pin :: String, dryRun :: Boolean, push :: Boolean } -> String -> String -> Effect Unit
runBuild opts composePath registryPath = do
  composeJson <- readYamlFile composePath
  registryJson <- readJsonFile registryPath
  let
    insts = ingestCompose composeJson <> ingestRegistry registryJson
    steps = buildPlan opts.registry opts.pin insts
    tag = "  (registry " <> opts.registry <> ", pin " <> opts.pin <> (if opts.push then "" else ", --no-push") <> ")"
  if opts.dryRun then do
    log ("quartermaster — build --dry-run " <> composePath <> " + " <> registryPath <> tag)
    log ""
    log (renderBuild steps)
    log ""
    log "(dry-run: the plan only. Drop --dry-run to build + push for real.)"
  else case steps of
    [] -> do
      log ("quartermaster — build " <> composePath <> " + " <> registryPath)
      log ""
      log "quartermaster build: nothing to build — no service builds from source (all prebuilt images)."
    _ -> do
      log ("quartermaster — build " <> composePath <> " + " <> registryPath <> tag)
      log ""
      results <- traverse runOne steps
      let okN = A.length (A.filter identity results)
      log ""
      log ("quartermaster build: " <> show okN <> "/" <> show (A.length results) <> " service(s) "
        <> (if opts.push then "built + shipped" else "built")
        <> (if okN == A.length results then "." else " — see failures above."))
  where
  runOne step = do
    let target = resolveTarget defaultTargets step.host
    log ("▶ " <> step.service <> " → " <> step.image <> (if isRemote target then "  (on " <> target.address <> ")" else ""))
    log ("  $ " <> buildInvocation target opts.push step)
    ok <- runBuildStep target opts.push step
    log (if ok then "  ✓ " <> step.service <> (if opts.push then " built + pushed" else " built")
               else "  ✗ " <> step.service <> " FAILED")
    pure ok

-- | Pull an optional `<name> <value>` flag out of the args wherever it appears.
takeFlag :: String -> Array String -> { value :: Maybe String, rest :: Array String }
takeFlag name args = case A.findIndex (_ == name) args of
  Just i
    | Just v <- A.index args (i + 1) ->
        { value: Just v, rest: fromMaybe args (A.deleteAt i args >>= A.deleteAt i) }
  _ -> { value: Nothing, rest: args }

-- | Pull an optional boolean flag (`--dry-run`, `--no-push`) out of the args:
-- | `found` iff present, `rest` with every occurrence removed.
takeBool :: String -> Array String -> { found :: Boolean, rest :: Array String }
takeBool name args =
  { found: A.elem name args, rest: A.filter (_ /= name) args }
