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

- **`quartermaster verify` — DONE (v1, local host).** The host-capability
  pre-flight: ingest the *same* compose + registry Bosun reads, derive each
  service's runtime requirement from its launch command, probe the host, and
  report whether each service is launchable there. This is the host-readiness
  half of the seam — the signal Bosun consumes before it runs anything.

  ```
  quartermaster verify <compose.yml> <registry.json>
  ```

- **Next:** the build/ship half (`quartermaster build` / `ship`) — produce the
  prebuilt artifact the deployment's `x-bosun.artifact` declares (build-once-ship,
  registry push), which Bosun's `# MANUAL: build-once-ship` advisory points at;
  remote (ssh-wrapped) verify via Bosun's `Target`; a native backend-go binary
  (Node-free, like `gnomon-bosun`).

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
