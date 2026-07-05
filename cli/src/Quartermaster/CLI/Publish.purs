-- | The effectful PUBLISH edge — runs a `PublishStep`'s `npx wrangler pages
-- | deploy …` for real. The command LINE is pure
-- | (`Quartermaster.Publish.publishShellLine`, the same string the CLI displays
-- | and the dry-run prints); this module only streams it.
-- |
-- | Like a build (and unlike the verify probe), a publish is long and chatty, so
-- | the foreign INHERITS stdio (wrangler upload progress streams straight to the
-- | terminal) and has no timeout. The upload is genuinely outward — the CLI gates
-- | it behind an explicit verb, not a default-on side effect.
module Quartermaster.CLI.Publish (runPublishStep, ensureCustomDomain) where

import Prelude

import Effect (Effect)
import Effect.Uncurried (EffectFn1, EffectFn2, runEffectFn1, runEffectFn2)
import Quartermaster.Publish (PublishStep, publishShellLine)

-- run `/bin/sh -c <cmd>` with INHERITED stdio (streaming, no capture, no
-- timeout); { ok: exit 0 }. Same shape as CLI.Build's runStreamImpl.
foreign import runStreamImpl :: EffectFn1 String { ok :: Boolean }

-- (project, domain) -> { ok, message }. Attach a custom domain to a CF Pages
-- project via the CF API, authenticating with wrangler's stored OAuth token (the
-- ambient auth the deploy just used). Node/curl edge — the token/API plumbing
-- lives here, not shell-escaped into the pure plan. Idempotent-ish: an
-- already-attached domain comes back ok:false with the CF message, non-fatal.
foreign import ensureCustomDomainImpl :: EffectFn2 String String { ok :: Boolean, message :: String }

-- | Publish one step locally (where wrangler + CF auth live). Returns whether the
-- | command exited cleanly. The caller displays the exact line first via
-- | `publishShellLine`.
runPublishStep :: PublishStep -> Effect Boolean
runPublishStep step =
  _.ok <$> runEffectFn1 runStreamImpl (publishShellLine step)

-- | Ensure a custom domain is attached to the CDN project (CF-4). Non-fatal: the
-- | deploy is the real verdict; a domain already-present or a perms gap returns
-- | ok:false with a message the caller surfaces without failing the publish.
ensureCustomDomain :: { project :: String, domain :: String } -> Effect { ok :: Boolean, message :: String }
ensureCustomDomain d = runEffectFn2 ensureCustomDomainImpl d.project d.domain
