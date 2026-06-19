-- | The `quartermaster verify` report renderer (entry-73: a `display` function,
-- | not a `Show`). Turns the pure verdicts into the human/CI-facing host-
-- | readiness summary. Total and deterministic, so a `--plan`-style golden diff
-- | and the node≡backend-go conformance both bite on it.
module Quartermaster.Report (renderVerify, renderBuild) where

import Prelude

import Bosun.Atoms (unAbsPath, unHost)
import Data.Array as A
import Data.Foldable (intercalate)
import Data.Maybe (Maybe(..))
import Quartermaster.Build (BuildStep)
import Quartermaster.Runtime (runtimeLabel)
import Quartermaster.Verify (Finding(..), Verdict, ready)

-- | Render the whole verify pass: one line per service (✓ ready / ✗ with its
-- | findings), then a one-line summary. Empty input ⇒ an explicit "nothing to
-- | verify" rather than a blank.
renderVerify :: Array Verdict -> String
renderVerify = case _ of
  [] -> "quartermaster verify: nothing to verify (no services ingested)."
  vs ->
    intercalate "\n" (map line vs)
      <> "\n\n" <> summary vs
  where
  line v
    | ready v = "  ✓ " <> label v <> " — " <> runtimeLabel v.requirement.runtime <> " ready"
    | otherwise =
        "  ✗ " <> label v <> "\n"
          <> intercalate "\n" (map (("      - " <> _) <<< findingText) v.findings)

  label v = hostTag v.requirement.host <> v.requirement.service

  hostTag = case _ of
    Just h -> "[" <> unHost h <> "] "
    Nothing -> ""

  findingText = case _ of
    RuntimeMissing rt -> "runtime not on this host: " <> runtimeLabel rt <> " (install it — Quartermaster's job)"
    CwdMissing p -> "working directory does not exist: " <> unAbsPath p
    Unclassified note -> note

  summary vs =
    let
      total = A.length vs
      okN = A.length (A.filter ready vs)
    in
      "quartermaster verify: " <> show okN <> "/" <> show total <> " service(s) launchable on their host"
        <> (if okN == total then " — host(s) ready." else " — provisioning needed (see ✗ above).")

-- | Render the build/ship plan (`quartermaster build --dry-run`): per service,
-- | the source context, target image, and the docker build+push commands. Empty
-- | ⇒ an explicit "nothing to build" (every service already ships a prebuilt
-- | image — the build-once-ship goal already met).
renderBuild :: Array BuildStep -> String
renderBuild = case _ of
  [] -> "quartermaster build: nothing to build — no service builds from source (all prebuilt images)."
  steps ->
    intercalate "\n\n" (map block steps)
      <> "\n\n" <> "quartermaster build: " <> show (A.length steps) <> " service(s) to build + ship."
  where
  block s =
    "  " <> s.service <> "  (" <> s.context <> " → " <> s.image <> ")\n"
      <> intercalate "\n" (map ("    $ " <> _) s.commands)
