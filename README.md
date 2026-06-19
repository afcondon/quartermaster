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

- **Next:** live build/push; a native backend-go binary (Node-free, like
  `gnomon-bosun`); richer host checks (`ERL_LIBS`, python venv, Rust codesign/TCC).

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
```
