-- | Homebrew as a TRACKED, not managed, layer of a host (`quartermaster brew
-- | check`). Nix owns the toolchain par; what is left in brew on a Mac is mostly
-- | casks — drivers, GUI apps, fonts — which Nix handles badly and which must
-- | not be installed unattended (a driver cask can restart coreaudiod under a
-- | running rig). So the host's Brewfile is a declaration Quartermaster reads,
-- | and this module computes the drift between it and what the host reports.
-- | It never plans an install.
-- |
-- | Both sides arrive in the same shape: the declared Brewfile, and the host's
-- | own `brew bundle dump --file=-`. One parser therefore reads both, and drift
-- | is set difference over (kind, name). Presence only — a Brewfile names
-- | packages, not versions.
module Quartermaster.Brew
  ( BrewKind(..)
  , BrewName
  , BrewEntry(..)
  , BrewDrift
  , parseBrewfile
  , brewDrift
  , brewDumpCommand
  , renderBrewDrift
  , renderBrewUnreadable
  , BrewEffect(..)
  , brewEffect
  , brewWrapScript
  ) where

import Prelude

import Data.Array as A
import Data.Foldable (intercalate)
import Data.Maybe (Maybe(..))
import Data.Set (Set)
import Data.Set as Set
import Data.String as S
import Data.String.Pattern (Pattern(..))
import Quartermaster.Exec (shellQuote)

-- | The three Brewfile kinds that are brew's own. `vscode`, `mas`, `go`, … lines
-- | are other package managers riding on `brew bundle`, and are excluded from
-- | the dump, so they are ignored on the declared side too.
data BrewKind = Tap | Formula | Cask

derive instance Eq BrewKind
derive instance Ord BrewKind

newtype BrewName = BrewName String

derive instance Eq BrewName
derive instance Ord BrewName

data BrewEntry = BrewEntry BrewKind BrewName

derive instance Eq BrewEntry
derive instance Ord BrewEntry

type BrewDrift =
  { missing :: Set BrewEntry -- declared, not installed
  , extra :: Set BrewEntry -- installed, not declared
  }

-- | Read a Brewfile (or a dump, which is one): every `tap|brew|cask "name" …`
-- | line, keeping only the name. Comments, blank lines, options after the name
-- | (`, link: false`) and other kinds are dropped.
parseBrewfile :: String -> Set BrewEntry
parseBrewfile = Set.fromFoldable <<< A.mapMaybe (parseLine <<< S.trim) <<< S.split (Pattern "\n")

parseLine :: String -> Maybe BrewEntry
parseLine line = do
  let word = S.takeWhile (_ /= S.codePointFromChar ' ') line
  kind <- kindOf word
  name <- firstQuoted (S.drop (S.length word) line)
  pure (BrewEntry kind (BrewName name))

kindOf :: String -> Maybe BrewKind
kindOf = case _ of
  "tap" -> Just Tap
  "brew" -> Just Formula
  "cask" -> Just Cask
  _ -> Nothing

firstQuoted :: String -> Maybe String
firstQuoted s = do
  open <- S.indexOf (Pattern "\"") s
  let rest = S.drop (open + 1) s
  close <- S.indexOf (Pattern "\"") rest
  let name = S.take close rest
  if S.null name then Nothing else Just name

brewDrift :: { declared :: Set BrewEntry, installed :: Set BrewEntry } -> BrewDrift
brewDrift { declared, installed } =
  { missing: Set.difference declared installed
  , extra: Set.difference installed declared
  }

-- | The read-only probe the CLI runs on the host. HOMEBREW_NO_AUTO_UPDATE is
-- | load-bearing: without it a "read-only" dump first updates brew itself
-- | (observed 2026-09-25 — it fetched a new portable Ruby). The PATH prefix
-- | covers a non-login shell on Apple silicon, where brew is not on the
-- | default PATH.
brewDumpCommand :: String
brewDumpCommand =
  "PATH=/opt/homebrew/bin:/usr/local/bin:$PATH " <> quietEnv <> " brew bundle dump --file=- " <> dumpScope

quietEnv :: String
quietEnv = "HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_ANALYTICS=1"

-- | What a Brewfile tracks: brew's own three kinds, none of the package
-- | managers `brew bundle` can also drive.
dumpScope :: String
dumpScope = "--tap --formula --cask --no-vscode --no-mas --no-go --no-cargo --no-uv --no-npm"

-- | The drift report: a verdict line first (so a probe can read line one), then
-- | the missing and extra entries grouped by kind, in Brewfile syntax so a line
-- | can be pasted straight into the Brewfile.
renderBrewDrift :: { host :: String, brewfile :: String } -> BrewDrift -> String
renderBrewDrift { host, brewfile } d
  | Set.isEmpty d.missing && Set.isEmpty d.extra =
      "quartermaster brew check: [" <> host <> "] IN STEP with " <> brewfile
  | otherwise =
      intercalate "\n" $
        [ "quartermaster brew check: [" <> host <> "] DRIFT from " <> brewfile
            <> " — " <> show (Set.size d.missing) <> " missing, "
            <> show (Set.size d.extra) <> " not in the Brewfile"
        ]
          <> section "missing (declared, not installed):" d.missing
          <> section "not in the Brewfile (installed, undeclared):" d.extra
  where
  section title entries
    | Set.isEmpty entries = []
    | otherwise = [ "", "  " <> title ] <> map (("    " <> _) <<< brewfileLine) (Set.toUnfoldable entries)

-- | The host's brew state could not be read (no brew, ssh down). Said plainly,
-- | never rendered as "everything is missing".
renderBrewUnreadable :: { host :: String, brewfile :: String } -> String
renderBrewUnreadable { host, brewfile } =
  "quartermaster brew check: [" <> host <> "] UNREADABLE — could not run `brew bundle dump` there;"
    <> " no drift computed against " <> brewfile

brewfileLine :: BrewEntry -> String
brewfileLine (BrewEntry kind (BrewName name)) = kindWord kind <> " \"" <> name <> "\""

kindWord :: BrewKind -> String
kindWord = case _ of
  Tap -> "tap"
  Formula -> "brew"
  Cask -> "cask"

-- | Does this brew invocation change what a Brewfile records? Only these
-- | subcommands do; everything else (list, info, search, services, doctor, …)
-- | passes through with nothing to record. `bundle` mutates except for its
-- | read-only subcommands.
data BrewEffect = ReadOnly | Mutating

derive instance Eq BrewEffect

brewEffect :: Array String -> BrewEffect
brewEffect args = case A.uncons (A.filter (not <<< S.contains (Pattern "-") <<< S.take 1) args) of
  Nothing -> ReadOnly
  Just { head: sub, tail } -> case sub of
    "bundle" -> case A.head tail of
      Just s | A.elem s [ "dump", "check", "list", "exec", "sh", "env", "edit" ] -> ReadOnly
      _ -> Mutating
    s | A.elem s mutatingSubcommands -> Mutating
    _ -> ReadOnly

mutatingSubcommands :: Array String
mutatingSubcommands =
  [ "install", "reinstall", "uninstall", "remove", "rm", "upgrade", "tap", "untap", "autoremove" ]

-- | The whole `quartermaster brew -- <args>` run, as one bash script: run the
-- | REAL brew with the caller's args, then — for a mutating command, whatever
-- | its exit status, since a partly-failed install still changed the host —
-- | re-dump the host's Brewfile and commit that one file. Brew's exit status is
-- | the script's, so the wrapper is transparent to anything scripting brew.
-- |
-- | This RECORDS, it does not gate: brew still changes by other routes (an
-- | absolute path, a launchd PATH, a self-updating cask, a .pkg), and
-- | `brew check` remains the backstop for those.
-- |
-- | The Brewfile comes from QUARTERMASTER_BREWFILE, which the private fleet's
-- | shim sets, so this public tool never learns where a fleet keeps its
-- | declarations. Unset, the command still runs and says it was not recorded.
-- | QUARTERMASTER_BREW_ACTIVE tells the shim to step aside should anything brew
-- | runs call `brew` again, and the real brew is always called by absolute
-- | path, so the wrapper can never recurse into itself.
brewWrapScript :: Array String -> String
brewWrapScript args =
  intercalate "\n" $
    [ "export QUARTERMASTER_BREW_ACTIVE=1"
    , "B=/opt/homebrew/bin/brew; [ -x \"$B\" ] || B=/usr/local/bin/brew"
    , "\"$B\" " <> intercalate " " (map shellQuote args)
    , "rc=$?"
    ]
      <> (if brewEffect args == Mutating then record else [])
      <> [ "exit $rc" ]
  where
  say msg = "echo " <> shellQuote ("quartermaster brew: " <> msg) <> " >&2"
  message = shellQuote ("brew " <> intercalate " " args <> ": recorded by quartermaster brew")
  record =
    [ "bf=\"${QUARTERMASTER_BREWFILE:-}\""
    , "if [ -z \"$bf\" ]; then"
    , "  " <> say "QUARTERMASTER_BREWFILE is unset, so this change is NOT recorded"
    , "elif ! " <> quietEnv <> " \"$B\" bundle dump --file=\"$bf\" --force " <> dumpScope <> " >/dev/null 2>&1; then"
    , "  " <> say "could not re-dump the Brewfile; run `quartermaster brew check` to see the drift"
    , "else"
    , "  d=$(dirname \"$bf\")"
    , "  if ! git -C \"$d\" rev-parse >/dev/null 2>&1; then"
    , "    " <> say "Brewfile re-dumped (not in a git repo, so not committed)"
    , "  elif git -C \"$d\" diff --quiet -- \"$bf\" && git -C \"$d\" ls-files --error-unmatch -- \"$bf\" >/dev/null 2>&1; then"
    , "    " <> say "Brewfile unchanged"
    , "  else"
    , "    git -C \"$d\" diff -U0 -- \"$bf\" | grep -E '^[-+](tap|brew|cask) ' | sed 's/^/quartermaster brew: recorded /' >&2"
    , "    git -C \"$d\" add -- \"$bf\" && git -C \"$d\" commit -q -m " <> message <> " -- \"$bf\" >&2"
    , "  fi"
    , "fi"
    ]
