#!/usr/bin/env bash
#
# mini-par.sh — bring the MacMini to par with the MBP's 2026-07-20 toolchain
# floor. RUN FROM THE MBP (the substrate-1 builder). REVIEW BEFORE RUNNING.
#
# What it does, in order:
#   P1  fast-forward the Mini's quartermaster checkout 2d08d41 -> 4823328
#   B1a sign the 18 quartermaster toolchain closures with substrate-1 and
#       nix-copy them to the Mini (overlay-built paths aren't on cache.nixos.org;
#       the Mini already trusts substrate-1, so they arrive without rebuild)
#   B1b nix profile install the 18 pins from the Mini's OWN flake (resolves to
#       the copied paths, no rebuild) + nix-direnv from nixpkgs = 19 pins
#   D   idempotent shell-rc: direnv hook + ~/.nix-profile/bin on PATH (.zshrc,
#       .zprofile) + ~/.config/direnv/direnvrc
#   C   direnv allow on any afc-work repo present with a committed .envrc
#
# SAFETY: this only ADDS toolchains + shell-rc lines. It touches NOTHING the
# Mini serves (Marginalia :3100/:3101, worklog-server, mysql, bosun, Atlantis).
# It is idempotent — safe to re-run. It does NOT copy the private signing key,
# does NOT clone the MBP's 89-repo working tree, does NOT alter LaunchAgents.
#
set -euo pipefail

MINI="andrew@andrews-mac-mini"
QM_MBP="/Users/afc/work/afc-work/ShapedSteer/quartermaster"      # builder path
KEY="$HOME/.config/nix/substrate-1.key"
NIX="/nix/var/nix/profiles/default/bin/nix"
SYS="aarch64-darwin"
export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"
export NIX_CONFIG="experimental-features = nix-command flakes"

# The 18 quartermaster#packages pins (nix-direnv comes from nixpkgs, added below).
PKGS=(cabal cargo erlang esbuild ffmpeg ghc go node purescript-language-server \
      purs purs-tidy python rebar3 rust-analyzer rustc spago stack tools)

echo "################ PREFLIGHT ################"
[ -f "$KEY" ] || { echo "FATAL: substrate-1 private key not at $KEY (are you on the MBP builder?)"; exit 1; }
# The par target is the shared truth on origin/main (what the Mini can pull),
# not the MBP's local HEAD (which may carry unpushed, flake-irrelevant commits
# like these provisioning scripts). flake.nix content is what actually matters;
# an unpushed provisioning commit doesn't change the emitted store paths.
git -C "$QM_MBP" fetch -q origin main || true
EXPECT="$(git -C "$QM_MBP" rev-parse --short origin/main)"
echo "par target (origin/main): $EXPECT"
echo "Mini nix: $(ssh "$MINI" 'nix --version')"
mini_clean="$(ssh "$MINI" 'cd ~/work/afc-work/ShapedSteer/quartermaster && git status --porcelain')"
[ -z "$mini_clean" ] || { echo "FATAL: Mini quartermaster worktree is dirty; resolve before par:"; echo "$mini_clean"; exit 1; }
echo "Mini quartermaster HEAD (pre): $(ssh "$MINI" 'cd ~/work/afc-work/ShapedSteer/quartermaster && git rev-parse --short HEAD')"

echo "################ P1: fast-forward Mini quartermaster ################"
ssh "$MINI" 'cd ~/work/afc-work/ShapedSteer/quartermaster && git pull --ff-only origin main'
mini_head="$(ssh "$MINI" 'cd ~/work/afc-work/ShapedSteer/quartermaster && git rev-parse --short HEAD')"
echo "Mini quartermaster HEAD (post): $mini_head"
[ "$mini_head" = "$EXPECT" ] || { echo "FATAL: expected $EXPECT (origin/main), got $mini_head"; exit 1; }

echo "################ B1a: sign + copy 18 closures MBP -> Mini ################"
# Pass flake installables straight to sign/copy (NOT hand-parsed store paths):
# some attrs are multi-output derivations (e.g. ffmpeg -> out/bin/dev/man), and
# nix resolves every output + its closure itself. No eval, no [*] word-splitting.
installables=()
for p in "${PKGS[@]}"; do installables+=("$QM_MBP#packages.$SYS.$p"); done
echo "signing ${#installables[@]} closures with substrate-1 (already-signed = no-op) ..."
"$NIX" store sign -k "$KEY" -r "${installables[@]}"
echo "copying to Mini (signed; -s lets the Mini pull cacheable paths itself) ..."
# --substitute-on-destination: the Mini fetches anything on cache.nixos.org
# directly; only the overlay-built (non-cached) paths transfer over ssh.
"$NIX" copy -s --to "ssh://$MINI" "${installables[@]}"

echo "################ B1b: install 19 pins from Mini's own flake ################"
ssh "$MINI" 'bash -s' <<'REMOTE'
set -euo pipefail
QM=~/work/afc-work/ShapedSteer/quartermaster
SYS=aarch64-darwin
PKGS=(cabal cargo erlang esbuild ffmpeg ghc go node purescript-language-server \
      purs purs-tidy python rebar3 rust-analyzer rustc spago stack tools)
installed="$(nix profile list)"
for p in "${PKGS[@]}"; do
  if grep -q "packages\.$SYS\.$p\$" <<<"$installed"; then
    echo "  = $p (already pinned)"
  else
    nix profile install "$QM#packages.$SYS.$p" && echo "  + $p"
  fi
done
if grep -q "nix-direnv" <<<"$installed"; then echo "  = nix-direnv (already pinned)"; else nix profile install nixpkgs#nix-direnv && echo "  + nix-direnv"; fi
REMOTE

echo "################ D: shell-rc (idempotent) ################"
ssh "$MINI" 'bash -s' <<'REMOTE'
set -euo pipefail
# .zshrc — direnv hook + nix-profile PATH precedence
if ! grep -q 'nix-profile/bin' ~/.zshrc 2>/dev/null; then
  printf '\n# --- nix toolchain floor (par with MBP, 2026-07-20) ---\neval "$(direnv hook zsh)"\nexport PATH="$HOME/.nix-profile/bin:$PATH"\n' >> ~/.zshrc
  echo "  .zshrc: added direnv hook + PATH"
else echo "  .zshrc: already has nix-profile PATH"; fi
# .zprofile — PATH for login shells
if ! grep -q 'nix-profile/bin' ~/.zprofile 2>/dev/null; then
  printf 'export PATH="$HOME/.nix-profile/bin:$PATH"\n' >> ~/.zprofile
  echo "  .zprofile: added PATH"
else echo "  .zprofile: already has nix-profile PATH"; fi
# direnvrc — source nix-direnv (needs the nix-direnv pin from B1b)
mkdir -p ~/.config/direnv
if [ ! -f ~/.config/direnv/direnvrc ]; then
  echo 'source "$HOME/.nix-profile/share/nix-direnv/direnvrc"' > ~/.config/direnv/direnvrc
  echo "  direnvrc: created"
else echo "  direnvrc: already present"; fi
REMOTE

echo "################ C: direnv allow present repos ################"
ssh "$MINI" 'bash -s' <<'REMOTE'
set -euo pipefail
export PATH="$HOME/.nix-profile/bin:$PATH"
shopt -s nullglob
for d in ~/work/afc-work/*/ ~/work/afc-work/*/*/; do
  if [ -f "${d}.envrc" ]; then ( cd "$d" && direnv allow 2>/dev/null && echo "  allowed ${d}" ); fi
done
REMOTE

echo "################ POSTFLIGHT: verify par ################"
ssh "$MINI" 'bash -s' <<'REMOTE'
set -euo pipefail
QM=~/work/afc-work/ShapedSteer/quartermaster
echo "  quartermaster: $(cd "$QM" && git rev-parse --short HEAD)  (should match MBP origin/main)"
echo "  profile pins:  $(nix profile list | grep -c '^Name:')  (want 19)"
echo "  purs: $(~/.nix-profile/bin/purs --version 2>/dev/null || echo MISSING)"
echo "  ghc:  $(~/.nix-profile/bin/ghc --version 2>/dev/null || echo MISSING)"
echo "  node: $(~/.nix-profile/bin/node --version 2>/dev/null || echo MISSING)"
echo "  stack:$(~/.nix-profile/bin/stack --version 2>/dev/null | head -1 || echo MISSING)"
REMOTE

echo "################ DONE — open a fresh Mini shell to pick up the rc changes ################"
