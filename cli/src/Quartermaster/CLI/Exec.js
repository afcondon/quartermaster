import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";

// EffectFn1 path -> { found, contents }. Read a file at the edge; never throws.
// found = false when absent (a repo may simply have no .envrc → no flake).
export const readFileImpl = (path) => {
  try {
    return { found: true, contents: readFileSync(path, "utf8") };
  } catch (e) {
    return { found: false, contents: "" };
  }
};

// EffectFn1 cmd -> Int. Run the exec script with LIVE streamed stdio and NO
// timeout — a wrapped `spago build` is minutes-long and megabytes of output; a
// buffered/timed exec would truncate it. `bash -c` so the rendered script (the
// source-daemon preamble + `exec …`) is interpreted by a real shell. Returns the
// wrapped command's exit code. Mirrors Quartermaster.CLI.Apply's streamImpl.
export const streamImpl = (cmd) => {
  const r = spawnSync("bash", ["-c", cmd], { stdio: "inherit" });
  if (typeof r.status === "number") return r.status;
  return r.signal ? 1 : 0;
};

// EffectFn1 Int -> Unit. Set the process exit code (deferred — lets streamed
// output flush) so the wrapped command's status becomes quartermaster's.
export const setExitCode = (code) => {
  process.exitCode = code;
};
