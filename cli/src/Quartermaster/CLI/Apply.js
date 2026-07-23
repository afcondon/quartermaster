import { execSync, spawnSync } from "node:child_process";

// EffectFn1 cmd -> { ok, out }. Run a probe synchronously (the no-Aff seam),
// capture trimmed stdout. ok = exit 0; out = trimmed stdout (empty on failure).
// Never throws. Mirrors Quartermaster.CLI.Probe's shProbeImpl (a 30s ceiling —
// an ssh probe round-trip, not a build).
export const captureImpl = (cmd) => {
  try {
    const out = execSync(cmd, { stdio: ["ignore", "pipe", "ignore"], timeout: 30000 })
      .toString()
      .trim();
    return { ok: true, out };
  } catch (e) {
    return { ok: false, out: ((e.stdout && e.stdout.toString()) || "").trim() };
  }
};

// EffectFn1 cmd -> Int. Run one apply phase with LIVE streamed stdio and NO
// timeout — the phases (Determinate Nix install, cache substitution of GHC/Rust/
// ffmpeg closures) are minutes-long and megabytes of output; a buffered/timed
// exec would truncate or kill them. `bash -c` so the ssh heredoc that
// applyInvocation renders is interpreted by a real shell. Returns the exit code.
export const streamImpl = (cmd) => {
  const r = spawnSync("bash", ["-c", cmd], { stdio: "inherit" });
  if (typeof r.status === "number") return r.status;
  return r.signal ? 1 : 0;
};
