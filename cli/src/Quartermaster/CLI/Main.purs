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
import Quartermaster.Apply (Shell(..), applyPlan, nixDirenvPin, parPins, renderPlan)
import Quartermaster.Build (buildInvocation, buildPlan)
import Quartermaster.CLI.Apply (mkApplyTarget, runApplyLive)
import Quartermaster.CLI.Build (runBuildStep)
import Quartermaster.CLI.Exec (runExecLive)
import Quartermaster.CLI.IO (argv, readJsonFile, readYamlFile)
import Quartermaster.CLI.Probe (probeRequirement)
import Quartermaster.CLI.Publish (ensureCustomDomain, runPublishStep)
import Quartermaster.Publish (automated, publishPlan, publishShellLine)
import Quartermaster.Report (renderBuild, renderPublish, renderVerify)
import Quartermaster.Verify (requirementsOf, verdictOf)

main :: Effect Unit
main = do
  raw <- argv
  let
    -- everything after the first `--` is a command argv to preserve VERBATIM
    -- (for `exec`); flags are parsed only from the tokens BEFORE it. The other
    -- verbs carry no `--`, so `before` is the whole arg list for them.
    split = splitAtDashDash raw
    rf = takeFlag "--registry" split.before
    pf = takeFlag "--pin" rf.rest
    ff = takeFlag "--flake" pf.rest
    sf = takeFlag "--system" ff.rest
    shf = takeFlag "--shell" sf.rest
    dr = takeBool "--dry-run" shf.rest
    np = takeBool "--no-push" dr.rest
    frc = takeBool "--force" np.rest
    args = frc.rest
    registry = fromMaybe "localhost:5001" rf.value
    pin = fromMaybe "latest" pf.value
  case args of
    [ "verify", composePath, registryPath ] -> runVerify composePath registryPath
    [ "build", composePath, registryPath ] ->
      runBuild { registry, pin, dryRun: dr.found, push: not np.found } composePath registryPath
    [ "publish", composePath, registryPath ] ->
      runPublish { dryRun: dr.found } composePath registryPath
    [ "apply", target ] ->
      runApply
        { dryRun: dr.found
        , force: frc.found
        , flake: fromMaybe "github:afcondon/quartermaster" ff.value
        , system: fromMaybe "x86_64-linux" sf.value
        , shellOverride: map parseShell shf.value
        }
        target
    [ "exec" ] -> runExec dr.found ff.value split.command
    _ -> log usage

parseShell :: String -> Shell
parseShell = case _ of
  "zsh" -> Zsh
  _ -> Bash

usage :: String
usage =
  "quartermaster — the provisioning companion to bosun\n\n"
    <> "  quartermaster verify <compose.yml> <registry.json>\n"
    <> "      can THIS host launch each declared service's runtime? (host pre-flight)\n\n"
    <> "  quartermaster build [--registry R] [--pin P] [--dry-run] [--no-push] <compose.yml> <registry.json>\n"
    <> "      build + ship the services that build from source (build-once-ship), on their\n"
    <> "      build host (ssh-wrapped for a remote target). --dry-run prints the plan only;\n"
    <> "      --no-push builds without the (outward) push.\n\n"
    <> "  quartermaster publish [--dry-run] <compose.yml> <registry.json>\n"
    <> "      ship each static-CDN site to its CDN (the cloudflare-pages-wrangler channel:\n"
    <> "      `npx wrangler pages deploy`). Runs locally, where wrangler + CF auth live.\n"
    <> "      --dry-run prints the plan only; the publish itself is outward, gated by the verb.\n\n"
    <> "  quartermaster apply [--dry-run] [--force] [--flake REF] [--shell bash|zsh] <target>\n"
    <> "      bring <target> (an ssh dest, or `local`) to the toolchain-floor par: probe it,\n"
    <> "      MISU-gate against the support catalog (non-known-good needs --force), then\n"
    <> "      ignition (install Determinate Nix) + convergence (nix profile install the par\n"
    <> "      pins from the flake), streamed live. The base path proven on BlackStar\n"
    <> "      (x86_64-linux self-substitutes from a public flake ref). --dry-run prints the\n"
    <> "      plan for --system SYS (default x86_64-linux) without probing; a live run detects\n"
    <> "      system + shell. Default flake github:afcondon/quartermaster.\n\n"
    <> "  quartermaster exec [--flake REF] [--dry-run] -- <cmd> [args...]\n"
    <> "      run <cmd> in the PROVISIONED environment regardless of the caller's shell:\n"
    <> "      source the nix daemon profile (which puts nix AND ~/.nix-profile/bin — the par\n"
    <> "      toolchain — on PATH), then, if the repo declares a flake dev-shell, drop into it.\n"
    <> "      Resolves the flake from --flake REF, else auto-detects `use flake <ref>` in the\n"
    <> "      cwd's .envrc, else runs bare against the profile toolchain. Everything after `--`\n"
    <> "      is the command, verbatim. --dry-run prints the exact script exec would run and\n"
    <> "      exits 0 without running it. The one rule an agent can follow: build via this."

-- | `quartermaster apply` — provision a target to par. `--dry-run` prints the
-- | plan (flag-driven, no probe); a live run probes the target, MISU-gates, and
-- | streams the phases (Quartermaster.CLI.Apply).
runApply
  :: { dryRun :: Boolean, force :: Boolean, flake :: String, system :: String, shellOverride :: Maybe Shell }
  -> String
  -> Effect Unit
runApply opts target =
  if opts.dryRun then do
    let
      spec =
        { flakeRef: opts.flake
        , system: opts.system
        , pins: parPins
        , nixpkgsPins: [ nixDirenvPin ]
        , shell: fromMaybe Bash opts.shellOverride
        }
    log ("quartermaster — apply " <> target <> "  (dry-run: " <> opts.system <> ", flake " <> opts.flake <> ")")
    log ""
    log (renderPlan (applyPlan spec))
  else
    runApplyLive
      { force: opts.force, flake: opts.flake, shellOverride: opts.shellOverride }
      (mkApplyTarget target)
      target

-- | `quartermaster exec` — run the post-`--` command in the provisioned
-- | environment (Quartermaster.CLI.Exec). The command is whatever followed `--`;
-- | its absence (no `--`, or nothing after it) is a usage error.
runExec :: Boolean -> Maybe String -> Maybe (Array String) -> Effect Unit
runExec dryRun explicitFlake = case _ of
  Just cmd
    | not (A.null cmd) -> runExecLive dryRun explicitFlake cmd
  _ -> do
    log "quartermaster exec: expected a command after `--`, e.g. `quartermaster exec -- spago build`."
    log ""
    log usage

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

runPublish :: { dryRun :: Boolean } -> String -> String -> Effect Unit
runPublish opts composePath registryPath = do
  composeJson <- readYamlFile composePath
  registryJson <- readJsonFile registryPath
  let
    insts = ingestCompose composeJson <> ingestRegistry registryJson
    steps = publishPlan insts
  if opts.dryRun then do
    log ("quartermaster — publish --dry-run " <> composePath <> " + " <> registryPath)
    log ""
    log (renderPublish steps)
    log ""
    log "(dry-run: the plan only. Drop --dry-run to publish for real.)"
  else case steps of
    [] -> do
      log ("quartermaster — publish " <> composePath <> " + " <> registryPath)
      log ""
      log "quartermaster publish: nothing to publish — no static-CDN service declared."
    _ -> do
      let parts = A.partition automated steps
      log ("quartermaster — publish " <> composePath <> " + " <> registryPath)
      log ""
      _ <- traverse skipNote parts.no
      results <- traverse runOne parts.yes
      let okN = A.length (A.filter identity results)
      log ""
      log ("quartermaster publish: " <> show okN <> "/" <> show (A.length results) <> " site(s) published"
        <> (if okN == A.length results then "." else " — see failures above."))
  where
  skipNote step =
    log ("• " <> step.service <> " → " <> step.channel <> ": not yet automated (MVP: cloudflare-pages-wrangler) — skipped")
  runOne step = do
    log ("▶ " <> step.service <> " → " <> step.channel <> " (" <> step.dest <> ")")
    log ("  $ " <> publishShellLine step)
    ok <- runPublishStep step
    if ok then do
      log ("  ✓ " <> step.service <> " published → " <> step.url)
      case step.domainAttach of
        Just d -> do
          res <- ensureCustomDomain d
          log ((if res.ok then "  ✓ custom domain: " else "  • custom domain: ") <> res.message)
        Nothing -> pure unit
    else log ("  ✗ " <> step.service <> " FAILED")
    pure ok

-- | Split the args at the FIRST `--`: `before` is the flag-and-verb portion,
-- | `command` is the verbatim argv after it (`Nothing` when no `--` is present).
-- | The `--` separator itself is dropped. This runs before any flag parsing so a
-- | `--flake`/`--registry` INSIDE the command is never mistaken for our own flag.
splitAtDashDash :: Array String -> { before :: Array String, command :: Maybe (Array String) }
splitAtDashDash args = case A.findIndex (_ == "--") args of
  Just i -> { before: A.take i args, command: Just (A.drop (i + 1) args) }
  Nothing -> { before: args, command: Nothing }

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
