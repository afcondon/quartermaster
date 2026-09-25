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
  ) where

import Prelude

import Data.Array as A
import Data.Foldable (intercalate)
import Data.Maybe (Maybe(..))
import Data.Set (Set)
import Data.Set as Set
import Data.String as S
import Data.String.Pattern (Pattern(..))

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
  "PATH=/opt/homebrew/bin:/usr/local/bin:$PATH"
    <> " HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_ANALYTICS=1"
    <> " brew bundle dump --file=- --tap --formula --cask"
    <> " --no-vscode --no-mas --no-go --no-cargo --no-uv --no-npm"

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
