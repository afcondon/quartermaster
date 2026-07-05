-- | The publish half of the seam (`quartermaster publish`) — the thing Bosun's
-- | `# MANUAL: static-CDN publish` advisory points ACROSS the seam at, the exact
-- | mirror of `Quartermaster.Build` for the CDN case. A `StaticCDN` service is a
-- | site awaiting publication; Quartermaster ships its artifact to the CDN via
-- | the declared `PublishChannel`. Bosun knows WHERE the artifact lives and which
-- | channel; it does not publish (see `bosun/docs/PROVISIONING-SEAM.md` and the
-- | `Bosun.Publish` module header, which anticipated this verb).
-- |
-- | MVP: the `cloudflare-pages-wrangler` channel (`npx wrangler pages deploy`).
-- | The git-backed channels are recognised but not yet automated — they produce a
-- | step with no `commands`, so the report names them rather than silently
-- | dropping them (the Quartermaster "never a silent pass" discipline).
-- |
-- | The PLAN is pure (the command strings), like Bosun's `applyScript`; running it
-- | is the effectful CLI edge (`Quartermaster.CLI.Publish`) — and gated, since a
-- | publish is outward. Unlike a build, a publish runs on the LOCAL machine (the
-- | one holding wrangler + CF auth), not the service's `host` (which is
-- | `cloudflare`, the serving substrate, not an ssh target), so there is no
-- | Target/ssh wrapping here.
module Quartermaster.Publish
  ( PublishStep
  , publishPlan
  , publishShellLine
  , automated
  ) where

import Prelude

import Bosun.Atoms (Host, unAbsPath, unUrl)
import Bosun.Executor (Executor(..))
import Bosun.Publish (PublishChannel(..))
import Bosun.Service (ServiceInstance)
import Data.Array as A
import Data.Foldable (intercalate)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String (Pattern(..), split, stripPrefix)

-- | One site to publish: its channel label + destination (cfProject / workdir),
-- | the site URL (for the one-time custom-domain note), and the ordered commands
-- | that ship it. `commands = []` means the channel is recognised but not yet
-- | automated (see module header). All-string, so it crosses to the exec edge / a
-- | Go twin with no decoding — the `BuildStep` discipline.
type PublishStep =
  { service :: String
  , host :: Maybe Host
  , channel :: String
  , dest :: String
  , url :: String
  , commands :: Array String
  -- The custom domain to ensure on the CDN project after the deploy (CF-4). Pure
  -- intent (project + bare host); the effectful edge enacts it via the CF API
  -- (`Quartermaster.CLI.Publish`), so no API/token logic leaks into the plan.
  , domainAttach :: Maybe { project :: String, domain :: String }
  }

-- | Derive the publish plan: one `PublishStep` per `StaticCDN` service. Every
-- | other executor is skipped (nothing to publish — it is served, not shipped).
publishPlan :: Array ServiceInstance -> Array PublishStep
publishPlan = A.mapMaybe step
  where
  step si = case si.executor of
    StaticCDN cdn -> Just (stepFor si.localName si.host cdn.publish (unUrl cdn.url))
    _ -> Nothing

-- | Whether a step is actually automated by this verb (has commands to run) —
-- | the report and the CLI partition on it.
automated :: PublishStep -> Boolean
automated = not <<< A.null <<< _.commands

stepFor :: String -> Maybe Host -> PublishChannel -> String -> PublishStep
stepFor service host chan url = case chan of
  -- The MVP channel. Three provisioning steps, in order:
  --   1. ensure the Pages project exists — `wrangler pages deploy` does NOT
  --      auto-create it (a first publish fails "project does not exist"), and
  --      creating the CDN project IS provisioning; `|| true` keeps it idempotent
  --      when it already exists (the deploy is the step whose success is the verdict).
  --   2. STAGE a clean copy — `wrangler pages deploy` serves the artifact dir
  --      WHOLESALE and does NOT honour `.assetsignore` (a Workers-assets feature,
  --      not Pages), so infra/meta files sitting next to the site (the x-bosun
  --      compose/registry, READMEs, .git) would be published verbatim. rsync the
  --      dir into a scratch stage minus those, and deploy the stage.
  --   3. deploy the staged dir.
  CloudflarePagesWrangler r ->
    let stage = "/tmp/qm-publish-" <> r.cfProject
    in
      { service
      , host
      , channel: "cloudflare-pages-wrangler"
      , dest: r.cfProject
      , url
      , commands:
          [ "npx wrangler pages project create " <> r.cfProject <> " --production-branch main || true"
          , "rm -rf " <> stage <> " && mkdir -p " <> stage
              <> " && rsync -a " <> rsyncExcludes <> " " <> unAbsPath r.artifactDir <> "/ " <> stage <> "/"
          , "npx wrangler pages deploy " <> stage
              <> " --project-name " <> r.cfProject
              <> " --branch main --commit-dirty=true"
          ]
      , domainAttach: Just { project: r.cfProject, domain: hostOf url }
      }
  -- Recognised, not yet automated (git-push channels): no commands, so the report
  -- names the gap instead of silently skipping.
  CloudflarePagesGit r ->
    unsupported service host "cloudflare-pages-git" r.cfProject url
  GitHubPagesRepoDir _ ->
    unsupported service host "github-pages-repo-dir" "(git push)" url

unsupported :: String -> Maybe Host -> String -> String -> String -> PublishStep
unsupported service host channel dest url =
  { service, host, channel, dest, url, commands: [], domainAttach: Nothing }

-- | The bare host of a URL — strip the scheme and any path, so `url`
-- | (`https://liquid-purescript.hylograph.net`) becomes the custom-domain name
-- | (`liquid-purescript.hylograph.net`) the CF Pages domains API wants.
hostOf :: String -> String
hostOf u = firstSeg (stripScheme u)
  where
  stripScheme x = case stripPrefix (Pattern "https://") x of
    Just r -> r
    Nothing -> fromMaybe x (stripPrefix (Pattern "http://") x)
  firstSeg x = fromMaybe x (A.head (split (Pattern "/") x))

-- | Infra/meta files that commonly sit alongside a hand-authored site but must
-- | NOT be published — the x-bosun compose/registry declaration, the source
-- | README, the git repo, and the `.assetsignore` that Pages doesn't honour.
-- | Rendered as rsync `--exclude=` flags for the staging copy.
rsyncExcludes :: String
rsyncExcludes = intercalate " " (map ("--exclude=" <> _) excludes)
  where
  excludes = [ ".git", "compose.yml", "registry.json", "README.md", ".assetsignore" ]

-- | The single shell line that ENACTS a publish step — the same `commands` the
-- | dry-run prints (one source of truth). Local (no ssh wrap): a publish runs
-- | where wrangler + CF auth live, not on the `cloudflare` serving substrate.
publishShellLine :: PublishStep -> String
publishShellLine step = intercalate " && " step.commands
