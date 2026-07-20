# Quartermaster's toolchain recipe, authored in PureScript

The substrate's provisioning recipe — which tools go in each work environment —
written in PureScript instead of by hand in Nix, in a **multi-interpreter**
shape: **one** shared data-structure IR, consumed by **two** backends.

```
                       src/Quartermaster/Recipe/IR.purs
                       (Prim-only: types + the `recipe` value —
                        the ONE source of truth, no prelude, so it
                        compiles under BOTH backends)
                                      │
                 ┌────────────────────┴────────────────────┐
                 ▼                                          ▼
   src/Quartermaster/Recipe/ToNix.purs        src/Quartermaster/Recipe/ToDocs.purs
   Nyx (PureScript → Nix)                     JS backend
   folds IR → `flake pkgs`                    folds IR → Markdown
   = { devShells; packages; }                 (src/Main.purs prints it)
   PROVEN byte-identical to flake.nix         bin/docs.sh → docs.generated.md
   bin/verify.sh → "ALL EQUIVALENT"
```

`IR.recipe` is a single PureScript value. `ToNix` lowers it, via the
[Nyx](../../../../purescript-backends/purescript-nix) backend, to a Nix function
of the package collection whose `devShells` + `packages` are **proven
byte-identical** (same derivation hashes) to the hand-written `flake.nix`.
`ToDocs` folds the *same* value, via the ordinary JS backend, to Markdown —
demonstrating the recipe is genuinely backend-neutral data, not Nix in disguise.

## Why this exists

The Nix-as-base-layer thesis says the Nix layer is a leveraged subsystem the
estate's lingua franca (PureScript) should reach. This is that, realized: the
recipe that provisions every machine is authored in the typed language the rest
of the estate uses, machine-checked against the Nix it replaces — and, because
it is plain data, re-interpretable (here, as docs). Two interpreters over one
value is the same "one spec, many lowerings" move as the polyglot backends.

## Layout

| Path | Role |
|------|------|
| `src/Quartermaster/Recipe/IR.purs` | Shared, Prim-only: `Package`/`Shell`/`Bundle`/`Recipe` types + the `recipe` value |
| `src/Quartermaster/Recipe/ToNix.purs` (+ `ToNix.nix` FFI) | Nyx-compiled fold → Nix `flake` |
| `src/Quartermaster/Recipe/ToDocs.purs` | JS-backend fold → Markdown |
| `src/Main.purs` | JS entry: `log (ToDocs.render IR.recipe)` |
| `src/Quartermaster/Recipe/ToNix.js` | Throwing FFI stub so `spago build` can compile the (Nix-only) ToNix module for the JS path |
| `verify.nix`, `bin/verify.sh` | drvPath-equivalence proof (Nyx recipe vs live flake.nix) |
| `bin/docs.sh` | Run ToDocs via the JS backend, print + save Markdown |
| `spago.yaml` | JS-backend workspace (self-contained root) |

## Build & verify

```bash
bin/verify.sh   # Nyx path: compile IR+ToNix (Prim-only) → prove hash-equivalence to flake.nix
bin/docs.sh     # JS path:  render the SAME IR value to Markdown (docs.generated.md)
```

`verify.sh` needs `purs` (0.15.x) + `nix` on PATH and the `pursnix` binary built
in `purescript-backends/purescript-nix`; it compiles **only** `IR` + `ToNix`
(both Prim-only) to CoreFn — the docs modules import the real prelude and are
excluded from that pass. `docs.sh` uses spago and the JS backend.

## Status

The recipe is a **proven-equivalent alternative** to the hand-written
`flake.nix`; it is not yet wired in as the source of truth. Retiring the
hand-written outputs (having `flake.nix` import the Nyx-compiled recipe) is a
deliberate, separate step — it changes the load-bearing flake both machines
depend on — and is left as an explicit decision.
