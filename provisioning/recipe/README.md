# Quartermaster's toolchain recipe, authored in PureScript

`src/Quartermaster/Recipe.purs` is the substrate's provisioning recipe —
which tools go in each work environment — written in PureScript instead
of by hand in Nix. The [Nyx](../../../../purescript-backends/purescript-nix)
backend (PureScript → Nix) compiles it; `flake` becomes a Nix function of
the package collection, and each environment / tool-bundle becomes the
corresponding Nix derivation.

It is **proven byte-identical** to the hand-written `flake.nix` outputs:
`bin/verify.sh` compiles the recipe through Nyx and compares derivation
hashes for all 8 devShells + 18 packages against the live flake. Result:
`ALL EQUIVALENT`.

## Why this exists

The Nix-as-base-layer thesis says the Nix layer is a leveraged subsystem
the estate's lingua franca (PureScript) should reach. This is that,
realized: the recipe that provisions every machine is authored in the
typed language the rest of the estate uses, and machine-checked against
the Nix it replaces. At two machines the practical need is modest; the
value is the proof-of-capability and readiness for per-host fleet config,
where types catch mistakes a hand-written multi-host Nix flake would not.

## Build & verify

```bash
bin/verify.sh          # compile through Nyx + prove hash-equivalence to flake.nix
```

Needs `purs` (0.15.x) + `nix` on PATH and the `pursnix` binary built in
`purescript-backends/purescript-nix`. The recipe is Prim-only PureScript
(a foreign `Derivation` type + records + arrays) — no prelude, no FFI
file; the package collection is passed in.

## Status

The recipe is a **proven-equivalent alternative** to the hand-written
`flake.nix`; it is not yet wired in as the source of truth. Retiring the
hand-written outputs (having `flake.nix` import the Nyx-compiled recipe)
is a deliberate, separate step — it changes the load-bearing flake both
machines depend on — and is left as an explicit decision.
