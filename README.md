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

- **`quartermaster build` — DONE (live).** The build/ship half: for each service
  that builds from source (build-once-ship — the thing Bosun's `# MANUAL` advisory
  points at), run `docker build` + `docker push` **on its build host** (ssh-wrapped
  for a remote target, in the target's workdir, with its `envPrefix`), shipping a
  pinned image to the registry so every host runs identical bytes. `--dry-run`
  prints the plan only; `--no-push` builds without the (outward) push. Proven live
  in both runtime lanes: node and the gnomon binary built+pushed the polyglot
  `edge` image to the mini's `localhost:5001` registry, same digest.

- **`quartermaster publish` — DONE (live).** The CDN-ship half (decision D-G2,
  the thing Bosun's `# MANUAL: static-CDN publish` advisory now points at). For
  each `StaticCDN` service (`x-bosun.static`, `cloudflare-pages-wrangler`
  channel), one shot: ensure the Pages project, stage a clean artifact (rsync
  minus infra/meta files — `wrangler pages deploy` ignores `.assetsignore`),
  `wrangler pages deploy`, then ensure the custom domain — attach it (wrangler
  OAuth, `pages:write`) and create the zone CNAME (a dedicated `QM_CF_DNS_TOKEN`,
  Zone:DNS:Edit — NOT `CLOUDFLARE_API_TOKEN`, which wrangler would hijack for the
  deploy). ~4 CF API calls, no retry loops. `--dry-run` prints the plan. Proven
  live 2026-07-05: `liquid-purescript.hylograph.net` end-to-end. The git-push
  channels are recognised but not yet automated (reported, never silently
  skipped). See `bosun/docs/PUBLISH-A-SITE.md`.

  ```
  quartermaster publish <compose.yml> <registry.json>
  ```

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

- **Next:** close the build-once-ship loop end-to-end (flip a deployment's
  build-from-source service to the QM-built pinned image so Bosun ships the built
  bytes and the `# MANUAL` advisory disappears); richer host checks (`ERL_LIBS`,
  python venv, Rust codesign/TCC, and the `DOCKER_CONFIG` non-interactive-build
  prep below); `--targets <file>` to layer a targets.json.

### Host prep note (the mini)

`quartermaster build`'s `docker build` pulls a public base image from docker.io.
Over a non-interactive ssh session the macOS keychain is locked, so the `desktop`
docker credential helper fails even for an anonymous public pull. The macmini
target's `envPrefix` therefore sets `DOCKER_CONFIG=/Users/andrew/.docker-nocreds`
— a docker config with no `credsStore`/`currentContext` (so no keychain helper,
default context) and a `cli-plugins` symlink (so `docker compose` still resolves).
That directory is currently **manual host prep**; creating/validating it is a
natural future `quartermaster` host-provisioning check.

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
scripts/qm-conformance.sh        # assert node ≡ gnomon, byte-for-byte (static fixtures)
scripts/qm-menagerie.sh          # behavioural dual-runtime tests (flip host conditions)
```

Two dual-runtime test harnesses, both run node CLI vs the gnomon binary:

- **`qm-conformance.sh`** — static byte-diff over committed fixtures (both verbs,
  all host shapes). Proves the output is identical for a *fixed* host state.
- **`qm-menagerie.sh`** — the behavioural rig (see [`docs/MENAGERIE.md`](docs/MENAGERIE.md)).
  Sets up controlled host conditions and *flips* them (a runtime on/off PATH, a
  cwd present/absent, a binary executable or not), asserting the verdict moves
  correctly and identically on both runtimes. This exercises the probe foreign's
  absence path — `command -v <missing>` → both must report `RuntimeMissing` — that
  the static fixtures never hit, the same way Bosun's Menagerie exercised real
  teardown.

The CLI edge has two foreigns — `IO` (read YAML/JSON, argv) and `Probe` (run a
synchronous `/bin/sh` check). Each has a JS twin (for `node cli/run.js`) and a Go
twin in `cli/go/` (for the native binary), the same app-owned-foreign pattern
Bosun uses. The shared argonaut/foreign-object decode twins come from the sibling
Bosun repo's `conformance/go` (one source of truth until a per-backend
runtime-libraries repo exists).
