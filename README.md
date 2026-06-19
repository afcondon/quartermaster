# Quartermaster

The **provisioning** companion to [Bosun](../bosun) (Marginalia #238, child of
ShapedSteer). Where Bosun *runs, observes and controls* the services that are
already aboard and runnable, Quartermaster *stocks the ship* — it gets a host into
a state where those services **can** run.

The boundary between the two is documented at
[`../bosun/docs/PROVISIONING-SEAM.md`](../bosun/docs/PROVISIONING-SEAM.md): the
contract surface is an **artifact reference + a host-readiness signal**.
Quartermaster produces (a built artifact at a known ref; a host provisioned and
verified ready); Bosun consumes (runs whatever the ref points to, then observes
it). **Bosun never invokes the build toolchain.**

## Status

- **`quartermaster verify` — DONE (local + remote).** The host-capability
  pre-flight: ingest the *same* compose + registry Bosun reads, derive each
  service's runtime requirement from its launch command, probe the host, and
  report whether each service is launchable there. Each service is probed on
  **its own host** (via Bosun's `Target`): laptop services locally, remote
  services over ssh — with the host's `envPrefix` (PATH etc.) applied, so a
  perfectly-installed `node`/`docker` on a remote box isn't a false negative just
  because a bare non-interactive ssh shell has a thin PATH. This is the
  host-readiness half of the seam — the signal Bosun consumes before it runs.

  ```
  quartermaster verify <compose.yml> <registry.json>
  ```

- **`quartermaster build` — DONE (dry-run).** The build/ship half: render the
  `docker build` + push plan for services that build from source (build-once-ship),
  the thing Bosun's `# MANUAL: build-once-ship` advisory points at. Live
  build/push is the next step (a push is outward, gated).

- **Native backend-go binary — DONE (Node-free).** Exactly like `gnomon-bosun`:
  `scripts/gnomon-quartermaster.sh` transpiles the *real* `Quartermaster.CLI.Main`
  to a single native Go binary (via backend-go) — no Node at runtime. It reads
  real `compose.yml` via `gopkg.in/yaml.v3` and runs probes through `/bin/sh`
  exactly like the node edge (so ssh-wrapped, envPrefix-aware remote verify works
  identically). `scripts/qm-conformance.sh` asserts the node CLI and the gnomon
  binary are **byte-identical** across both verbs and all host shapes (Process,
  Container, and mixed mbp+macmini over ssh). Output is sorted in the pure core
  (`Verify.requirementsOf` by host,service) so a passing diff means true
  equivalence, not just the same set in a different order.

- **Next:** live build/push; richer host checks (`ERL_LIBS`, python venv, Rust
  codesign/TCC); `--targets <file>` to layer a targets.json.

## Architecture

Same ethos as Bosun — typed model, pure core, thin effectful edge, PureScript.
The shared deployment vocabulary (the artifact model, `Target`/host identity, the
ingest adapters) is **path-imported from the Bosun workspace next door**
(`spago.yaml` `extraPackages`), not duplicated — Quartermaster reuses
`bosun-core` + `bosun-adapters` and adds its own provisioning layer.

| package | what |
|---|---|
| `quartermaster-core` | pure: the `Runtime` model + capability requirements + the verify report |
| `quartermaster-cli`  | the `quartermaster` entrypoint + the synchronous probe/IO edges |

```
spago build            # compile
npm install            # js-yaml, for running the node CLI
node cli/run.js verify <compose> <registry>

# …or Node-free, via the backend-go native binary (rebuilds when sources change):
scripts/gnomon-quartermaster.sh verify <compose> <registry>
scripts/qm-conformance.sh        # assert node ≡ gnomon, byte-for-byte
```

The CLI edge has two foreigns — `IO` (read YAML/JSON, argv) and `Probe` (run a
synchronous `/bin/sh` check). Each has a JS twin (for `node cli/run.js`) and a Go
twin in `cli/go/` (for the native binary), the same app-owned-foreign pattern
Bosun uses. The shared argonaut/foreign-object decode twins come from the sibling
Bosun repo's `conformance/go` (one source of truth until a per-backend
runtime-libraries repo exists).
