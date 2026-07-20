# Quartermaster's toolchain recipe, authored in PureScript

The substrate's provisioning recipe — which tools go in each work environment —
written in PureScript instead of by hand in Nix, in a **multi-interpreter**
shape: **one** shared data-structure value, folded by **three** interpreters.

This is the first real client of the polyglot-template **data axis** (the
`polyglot-template` B layout, generalized to two axes — see that repo's
`docs/TWO-AXES.md`). `core/` holds a Prim-only value; each `columns/<interp>/`
is an interpreter that folds it. Because each interpreter lives in its own
column, the Nix-only interpreter needs **no** JS FFI stub — the throwing
`ToNix.js` the old flat layout carried is gone.

```
core/src/Quartermaster/Recipe/IR.purs
  (Prim-only: types + the `recipe` value — the ONE source of truth,
   no prelude, so it compiles under every interpreter's backend)
                              │
   ┌──────────────────────────┼──────────────────────────┐
   ▼                          ▼                          ▼
columns/nix/            columns/docs/              columns/graph/
  ToNix.purs + .nix FFI   ToDocs.purs + Main.purs    ToGraph.purs + Main.purs
  Nyx (PureScript → Nix)  JS backend                 JS backend
  IR → `flake pkgs`       IR → Markdown              IR → Graphviz DOT
  = { devShells; packages }  (Main prints it)         (→ SVG via `dot`)
  PROVEN byte-identical   bin/docs.sh                bin/graph.sh
   to flake.nix           → docs.generated.md        → recipe.dot + recipe.svg
  bin/verify.sh → "ALL EQUIVALENT"
```

Three interpreters close the trilogy the recipe-as-eDSL was meant to serve:
**(a)** Nix, **(b)** a graphical representation, **(c)** documentation — over one
value, each an append-only column that never touches `core/`. The graph earns
its keep: it makes VISIBLE what the flat lists hide — which tools are *shared*
across shells (amber nodes), showing e.g. that `purerl` is the union shell,
sharing the PureScript kit with `purescript` and the BEAM kit with `erlang`.

`IR.recipe` is a single PureScript value. `columns/nix` lowers it, via the
[Nyx](../../../../purescript-backends/purescript-nix) backend, to a Nix function
of the package collection whose `devShells` + `packages` are **proven
byte-identical** (same derivation hashes) to the hand-written `flake.nix`.
`columns/docs` folds the *same* value, via the ordinary JS backend, to Markdown —
demonstrating the recipe is genuinely backend-neutral data, not Nix in disguise.

## Why this exists

The Nix-as-base-layer thesis says the Nix layer is a leveraged subsystem the
estate's lingua franca (PureScript) should reach. This is that, realized: the
recipe that provisions every machine is authored in the typed language the rest
of the estate uses, machine-checked against the Nix it replaces — and, because
it is plain data, re-interpretable (here, as docs). Two interpreters over one
value is the same "one spec, many lowerings" move as the polyglot backends; the
B layout makes each lowering a first-class, append-only column.

## Layout (data axis of the B shape)

| Path | Role |
|------|------|
| `core/src/Quartermaster/Recipe/IR.purs` | Shared, Prim-only: `Package`/`Shell`/`Bundle`/`Recipe` types + the `recipe` value |
| `core/spago.yaml` | The core package — **no** dependencies (Prim-only) |
| `columns/nix/src/Quartermaster/Recipe/ToNix.purs` (+ `ToNix.nix` FFI) | Nyx interpreter → Nix `flake` |
| `columns/nix/spago.yaml` | `backend: cmd: "true"` (→ CoreFn); depends only on core |
| `columns/docs/src/Quartermaster/Recipe/ToDocs.purs` | JS interpreter → Markdown |
| `columns/docs/src/Main.purs` | JS entry: `log (ToDocs.render IR.recipe)` |
| `columns/docs/spago.yaml` | JS backend; depends on core + prelude/arrays/strings/effect/console |
| `columns/graph/src/Quartermaster/Recipe/ToGraph.purs` | JS interpreter → Graphviz DOT (shells + shared tools) |
| `columns/graph/src/Main.purs` | JS entry: `log (ToGraph.render IR.recipe)` |
| `verify.nix`, `bin/verify.sh` | drvPath-equivalence proof (Nyx recipe vs live flake.nix) |
| `bin/docs.sh` | Run the docs column via the JS backend, print + save Markdown |
| `bin/graph.sh` | Run the graph column, emit `recipe.dot` and (via `dot`) `recipe.svg` |

## Build & verify

```bash
bin/verify.sh   # nix column:   spago build (CoreFn) → Nyx → prove hash-equivalence to flake.nix
bin/docs.sh     # docs column:  render the SAME IR value to Markdown (docs.generated.md)
bin/graph.sh    # graph column: render the SAME IR value to a graph (recipe.dot → recipe.svg)
```

`verify.sh` needs `purs` (0.15.x) + `nix` on PATH and the `pursnix` binary built
in `purescript-backends/purescript-nix`. It builds the `nix` column, which — by
depending only on the Prim-only `core` — compiles **exactly** `IR` + `ToNix`
(no prelude, no docs modules) to CoreFn, then runs Nyx. `docs.sh` uses spago and
the JS backend in the `docs` column.

## Status

The recipe is a **proven-equivalent alternative** to the hand-written
`flake.nix`; it is not yet wired in as the source of truth. Retiring the
hand-written outputs (having `flake.nix` import the Nyx-compiled recipe) is a
deliberate, separate step — it changes the load-bearing flake both machines
depend on — and is left as an explicit decision.
