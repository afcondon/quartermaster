-- | `quartermaster exec` — run a command in the PROVISIONED environment,
-- | regardless of the caller's shell. The gap this closes: `apply` installs the
-- | par toolchain under `~/.nix-profile/bin` and wires PATH into the interactive
-- | rc + login profile, but a NON-interactive / agent shell sources neither, so
-- | `spago`/`nix` are "command not found" though installed 20 mm away. `exec`
-- | sources the daemon profile (which puts both `nix` and `~/.nix-profile/bin` on
-- | PATH) and, if the repo declares a flake dev-shell, drops into it — so an agent
-- | can be told ONE rule ("build via `quartermaster exec`") instead of guessing a
-- | `/nix/var/...` reach-around. See docs/spec-agent-shell-toolchain-path.md.
-- |
-- | This is the pure half: `execScript` is a total function from an `ExecSpec` to
-- | the shell script TEXT (the applyScript discipline — the plan lives in core as
-- | command strings; the file read + `bash -c` run are the CLI edge's job). The
-- | `.envrc` flake auto-detection is likewise split: the parse (`parseFlakeRef`)
-- | is pure here; the CLI edge only performs the read.
module Quartermaster.Exec
  ( ExecSpec
  , execScript
  , parseFlakeRef
  ) where

import Prelude

import Data.Array as A
import Data.Foldable (intercalate)
import Data.Maybe (Maybe(..))
import Data.String as String
import Data.String.Pattern (Pattern(..), Replacement(..))

-- | "run THIS command, optionally inside THIS flake dev-shell". `command` is the
-- | argv verbatim (program + args, everything after `--`); `flakeRef` is the
-- | resolved dev-shell ref (`--flake` override, or `.envrc` auto-detect), or
-- | `Nothing` to run against the profile toolchain already on PATH.
type ExecSpec =
  { flakeRef :: Maybe String
  , command :: Array String
  }

-- | The daemon-profile preamble: put `nix` on PATH, source the daemon profile
-- | (which ALSO puts `~/.nix-profile/bin` — the par toolchain — on PATH; guarded
-- | so a machine without it degrades to a plain passthrough), and enable flakes.
-- | Verbatim from the spec's locked design (docs/spec-agent-shell-toolchain-path.md).
preamble :: Array String
preamble =
  [ "export PATH=\"/nix/var/nix/profiles/default/bin:$PATH\""
  , "[ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ] && . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
  , "export NIX_CONFIG='experimental-features = nix-command flakes'"
  ]

-- | Render the exec script: the preamble, then either `exec nix develop <ref>
-- | --command <argv>` (flake resolved) or a bare `exec <argv>` (the par toolchain
-- | is already on PATH from the preamble). `exec` so the command replaces the
-- | shell and its exit status is the script's. Each token is single-quoted so the
-- | argv is preserved verbatim under word-splitting without a redesign of intent.
execScript :: ExecSpec -> String
execScript spec = intercalate "\n" (preamble <> [ runLine ])
  where
  cmd = intercalate " " (map shellQuote spec.command)
  runLine = case spec.flakeRef of
    Just ref -> "exec nix develop " <> shellQuote ref <> " --command " <> cmd
    Nothing -> "exec " <> cmd

-- | POSIX single-quote a token: wrap in `'…'`, and render any embedded quote as
-- | the `'\''` splice. Keeps args/flags/paths with spaces or metacharacters intact.
shellQuote :: String -> String
shellQuote s = "'" <> String.replaceAll (Pattern "'") (Replacement "'\\''") s <> "'"

-- | Auto-detect a flake dev-shell ref from `.envrc` contents: the first line that
-- | (trimmed) begins `use flake ` yields the following whitespace-delimited token
-- | (e.g. `use flake ../quartermaster#purescript` → `../quartermaster#purescript`).
-- | `Nothing` when no such line is present. Pure — the read happens at the edge.
parseFlakeRef :: String -> Maybe String
parseFlakeRef contents = A.findMap lineRef (String.split (Pattern "\n") contents)
  where
  lineRef line = case String.stripPrefix (Pattern "use flake ") (String.trim line) of
    Just rest -> A.head (A.filter (_ /= "") (String.split (Pattern " ") (String.trim rest)))
    Nothing -> Nothing
