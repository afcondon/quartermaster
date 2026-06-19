# The Quartermaster Menagerie

Behavioural, dual-runtime tests of Quartermaster's **provisioning muscle** — the
analog of [Bosun's Menagerie](../../bosun/docs/MENAGERIE.md).

`scripts/qm-menagerie.sh`

## What it's for

Bosun's Menagerie launches live specimen processes and watches *supervision*
(launch / track / teardown) — the muscle there is `os-exec`, and it earned its
keep by catching `setsid`/zombie-reap fidelity bugs where the Go exec foreign
diverged from node in ways a byte-diff over static output couldn't see.

Quartermaster doesn't launch anything. Its muscle is the **probe edge**:
`command -v` / `test -d` / `test -x`, run locally or ssh-wrapped, by the
`shProbeImpl` foreign (a JS twin for `node cli/run.js`, a Go twin for the native
`gnomon-quartermaster` binary). So the Menagerie's specimens are controlled
**host conditions**, and each scenario *flips* one — a runtime on/off PATH, a cwd
that exists or not, a binary that's executable or not — runs `verify` under both
runtimes, and asserts two things:

1. **fidelity** — the node and gnomon outputs are byte-identical;
2. **correctness** — the verdict matches the known ground truth, and *moves* the
   right way when the condition flips.

## Why the static byte-diff (`qm-conformance.sh`) isn't enough

`scripts/qm-conformance.sh` runs both runtimes over committed Bosun fixtures and
diffs the output. But those fixtures are probed against whatever the dev box
*happens* to have — `python3` present, `/srv/*` absent — so the **absence path**
of the probe foreign is never exercised on a deliberate present→absent flip:
`command -v <missing>` exits nonzero, node's `execSync` throws, Go's `exec`
returns an error, and both must land on the same `RuntimeMissing`. The Menagerie
sets up that absence on purpose, then confirms both runtimes agree. (Same logic
as Bosun proving teardown on a process it actually launched.)

## The specimens

All registry rows (verify ingests `compose ∪ registry`; an empty compose keeps
the muscle controllable from one file). Each `startCommand` classifies to a
distinct `ProbeSpec` (see `Quartermaster.Runtime`):

| specimen       | startCommand                       | ProbeSpec            |
|----------------|------------------------------------|----------------------|
| `onpath`       | `cd <work> && quux serve …`        | `CommandOnPath quux` + cwd |
| `binary`       | `cd <work> && <bin>/blob run`      | `FileExecutable blob` + cwd |
| `nocwd`        | `quux daemon`  (no `cd`)           | `CommandOnPath quux`, no cwd |
| `unclassified` | `cd <work> &&`  (empty command)    | `Unknown` → reported, never silently passed |
| `container`    | `docker compose up`               | `EngineAny` |
| `remote` *(opt-in)* | `cd /srv/archive && node …` (host macmini) | `CommandOnPath node` over ssh |

## The scenarios (the flips)

- **S1 all present** — quux on PATH, blob executable, work/ exists → everything
  ready except `unclassified` (correctly flagged, not passed).
- **S2 runtime missing** — remove `quux`: both quux-needing services flip to
  `RuntimeMissing`; `binary` (a different probe) stays ready.
- **S3 cwd missing** — remove `work/`: the two services with a cwd flip to
  `CwdMissing`; `nocwd` stays ready.
- **S4 binary not executable** — `chmod -x blob`: the `FileExecutable` probe flips
  to `RuntimeMissing`; the `CommandOnPath` service is unaffected.
- **S5 remote** *(opt-in, `QM_MEN_REMOTE=1`)* — a macmini specimen exercises the
  ssh-wrapped, envPrefix-aware probe through the Go shProbe twin (read-only:
  `node` is found over ssh, `/srv/archive` isn't → `CwdMissing`). The point is
  node ≡ gnomon *over ssh*.

## Running

```
scripts/qm-menagerie.sh                 # offline; builds the gnomon binary if stale
QM_MEN_REMOTE=1 scripts/qm-menagerie.sh # add the macmini ssh specimen
```

Hermetic — it builds a throwaway stage under `/tmp` (fake `quux`/`blob`, a work
dir, the specimen registry referencing the stage) and cleans up on exit. No
committed machine-specific paths.

## Status

Dual-runtime DONE (2026-06-19). All five scenarios pass: the probe muscle moves
correctly and identically on node and gnomon, including over ssh.
