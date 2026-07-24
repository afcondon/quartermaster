# Spec: the provisioned toolchain must be reachable from non-interactive shells

**Status:** requirement, unbuilt. Raised 2026-07-24 while dogfooding (building
`minard-for-nix` from a Claude agent shell — the toolchain was installed but
invisible, and the build only worked after a manual `nix develop` reach-around).

## The gap

`quartermaster apply` provisions the par toolchain into `~/.nix-profile/bin`
(nix, spago, purs, node, direnv, the whole par — direnv rides the `tools`
bundle). It then makes that toolchain **reachable** by writing a PATH prepend
into two places only:

- the interactive rc — `.zshrc` / `.bashrc` (`export PATH="$HOME/.nix-profile/bin:$PATH"`)
- the login profile — `.profile` / `.zprofile`

A **non-login, non-interactive shell sources neither.** That is exactly the
shell an automation agent runs under: a Claude Code session, `sh -c "…"`, a CI
step, a `ssh host '<cmd>'` one-shot. In all of those, the provisioned toolchain
is present on disk but **not on PATH** — `spago: command not found`, even though
`spago` is 20 mm away under `~/.nix-profile/bin`.

Concretely, this is what a fresh agent shell has to do today to build a repo
whose `.envrc` is `use flake ../quartermaster#purescript`:

```bash
export PATH="/nix/var/nix/profiles/default/bin:$PATH"      # find nix at all
export NIX_CONFIG='experimental-features = nix-command flakes'
nix develop ../quartermaster#purescript --command spago build   # then reach the shell
```

None of that should be necessary. The whole install-UX north-star is *"cold-boot
from a minimal ssh footprint, then everything just works."* It currently works
for **a human at an interactive terminal** and not for **an agent** — and in
this ecosystem agents are first-class operators, so the promise has to cover
them.

## Why it matters (dogfooding)

- The ecosystem is built *by* agents. If a freshly-par'd machine can't be built
  on by an agent without a manual reach-around, the machine isn't actually a
  turnkey fleet node — it's a fleet node with an asterisk that only a
  human-in-a-login-shell can cash.
- It silently defeats `bosun`/`quartermaster`'s own non-interactive invocations
  the moment they run on a machine where the tools came from the profile rather
  than a system package.

## Candidate remedies (the design choice this spec exists to make)

1. **System-level PATH placement, not rc-gated.**
   - macOS: `/etc/paths.d/nix-profile` (read by `path_helper` for *all* shells,
     login or not) — but per-user `~/.nix-profile` complicates a system file;
     may need `/etc/paths.d` pointing at the per-user profile, or a per-user
     LaunchAgent `setenv`.
   - Linux: `/etc/profile.d/` is still login-gated; the robust answer is a
     systemd user-environment `environment.d` entry or a `/etc/environment`
     PATH — both non-rc.
   - Trade-off: touches system files (par currently only touches `$HOME`); needs
     the transient-sudo category, and it's OS-divergent (exactly the kind of
     baked-in assumption we've been careful about).

2. **A toolkit-aware exec: `quartermaster exec -- <cmd>`.**
   - Runs `<cmd>` with the provisioned profile (and optionally a repo's flake
     dev-shell) sourced, regardless of the caller's shell. Portable, no system
     files, no OS divergence. The cost: callers must know to prefix it — but
     agents can be *told* one rule ("build via `quartermaster exec`") far more
     reliably than they can be expected to guess `nix develop` incantations.
   - This is the most dogfooding-shaped answer: it's a Quartermaster verb, it's
     the same everywhere, and it degrades gracefully (if the profile is already
     on PATH it's a no-op passthrough).

3. **Standardize automation on login shells** (`bash -lc "<cmd>"`, agent runner
   configured to spawn login shells).
   - Cheapest, but fragile: it relies on every caller remembering, and `-l`
     drags in the *interactive* rc's other side effects. A convention, not a
     guarantee.

## Recommendation

Lean toward **(2) `quartermaster exec`** as the primary answer — it's portable,
system-file-free, OS-uniform, and it's the one instruction an agent can follow
every time — with **(1)** as an optional per-machine ergonomic layer for humans
who want a bare `spago` to work in any shell. Decide before the next machine is
provisioned, so the fix ships as part of `apply` rather than as a retrofit.

## Acceptance test

From a **fresh non-interactive shell** on a par'd machine (no rc sourced, e.g.
`env -i bash -c '…'` or a Claude agent shell), building any ecosystem repo
succeeds with **one documented step and no `/nix/var/...` reach-around**.
