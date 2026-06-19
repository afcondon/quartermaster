-- | The `quartermaster` CLI entrypoint.
-- |
-- |   quartermaster verify <compose.yml> <registry.json>
-- |     ingest the SAME deployment sources Bosun reads → derive each service's
-- |     host-capability requirement → probe the (local) host → print the
-- |     readiness report. This is the host-readiness half of the Bosun⇄
-- |     Quartermaster seam: the signal Bosun consumes before it runs anything.
module Quartermaster.CLI.Main where

import Prelude

import Bosun.Adapters.Compose (ingestCompose)
import Bosun.Adapters.Registry (ingestRegistry)
import Data.Traversable (traverse)
import Effect (Effect)
import Effect.Console (log)
import Quartermaster.CLI.IO (argv, readJsonFile, readYamlFile)
import Quartermaster.CLI.Probe (probeRequirement)
import Quartermaster.Report (renderVerify)
import Quartermaster.Verify (requirementsOf, verdictOf)

main :: Effect Unit
main = do
  args <- argv
  case args of
    [ "verify", composePath, registryPath ] -> runVerify composePath registryPath
    _ -> log usage

usage :: String
usage =
  "quartermaster — the provisioning companion to bosun\n\n"
    <> "  quartermaster verify <compose.yml> <registry.json>\n"
    <> "      can THIS host launch each declared service's runtime? (host pre-flight)"

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
