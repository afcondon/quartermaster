# Spec: the dual-runtime conformance harness must cover EVERY verb

**Status:** requirement, ready to build. Raised 2026-07-24 after the Go (Gnomon)
binary was found to have been unbuildable since the `apply` verb landed
(`5499eee`) — `apply` and `publish` shipped Node-only, their Go FFI twins never
written, and **nothing caught it** because the conformance harness only tests
`verify` and `build --dry-run`.

## The gap

`scripts/qm-conformance.sh` asserts the Node CLI and the Gnomon backend-go binary
produce byte-identical output — the regression lock for the "Quantermaster runs
Node-free" guarantee. But its `assert_identical` helper is hard-shaped to verbs
that take `<compose.yml> <registry.json>` as their final two args:

```bash
node cli/run.js "$verb" "$@" "$dir/compose.yml" "$dir/registry.json"
```

So it can only ever test **verify** and **build** (and, in principle, publish).
`apply` (which takes an ssh/local **target**) and `exec` (which takes `-- <cmd>`)
have argument shapes the helper can't express, so they were never in the net.
Result: a whole verb's Go column can be missing its FFI twins — the link fails,
the binary doesn't build — and every green run of the harness still says "ALL
IDENTICAL," because it never asked the binary to do the broken thing.

The guarantee is only as strong as its coverage. Today it covers 2 of 5 verbs.

## Requirement

**Every verb the CLI dispatches gets a conformance case, and the harness fails if
any verb's Node and Go output diverge — including "the Go binary won't build."**

Concretely:

1. **Generalize the harness** so a case can pass an arbitrary argument list, not
   only `<compose> <registry>`. Add an `assert_raw <label> -- <args…>` helper
   alongside the existing compose/registry one; keep the old helper as a thin
   wrapper over it.

2. **A case per verb, each a PURE/plan-only invocation** (no outward side
   effects — the applyScript discipline means every verb has a pure plan to
   compare):
   - `verify` — existing (3 fixtures). Keep.
   - `build --dry-run` — existing. Keep (optionally add a prebuilt-image fixture
     so the "nothing to build" branch is also compared).
   - `publish --dry-run` — NEW. Needs a fixture whose registry declares a
     static-CDN service, so the plan is non-empty; also assert the empty case.
   - `apply --dry-run --system <sys> [--shell …] <target>` — NEW. The dry-run
     plan is flag-driven and probe-free, so it is deterministic and comparable.
     Cover at least one linux and one darwin `--system`, and both shells.
   - `exec --dry-run -- <cmd>` — NEW. **Requires adding `--dry-run` to the exec
     verb** (see 3).
   - `usage` — NEW. Invoke with no args (and/or an unknown verb); the help text
     must be byte-identical too (it is emitted from the same pure `usage` value).

3. **Add `exec --dry-run`** — print the generated script (`Quartermaster.Exec`'s
   pure `execScript`) instead of running it. This is both the conformance surface
   for exec AND a genuinely useful feature ("show me exactly what `exec` would
   run"), and it keeps exec honest to the applyScript discipline like the other
   verbs. Flag parsing must place `--dry-run` *before* the `--` split so it is
   never mistaken for part of the wrapped command.

4. **Make it runnable so it can't rot again.** The harness already rebuilds the
   Gnomon binary as its first step, so *running it* is what would have caught the
   broken build. Expose it as a `make conformance` target (and reference it from
   `docs/MENAGERIE.md`) so it is a one-command gate, and note in the repo's
   contributor docs that **adding or changing a verb requires a conformance
   case** — the same discipline bosun's `go-conformance.sh` enforces.

## Acceptance test

- `scripts/qm-conformance.sh` (or `make conformance`) builds the Gnomon binary
  and asserts Node ≡ Go for **verify, build, publish, apply, exec, and usage**.
- Deleting any one verb's `cli/go/*_foreign.go` twin (so the Go binary fails to
  build) makes the harness **fail**, not silently pass — i.e. a build failure is
  a conformance failure.
- `quartermaster exec --dry-run -- spago build` prints the script it would run
  and exits 0 without running it, byte-identical across Node and Go.
