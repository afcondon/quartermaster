import { execSync } from "node:child_process";

// EffectFn1 cmd -> { ok }. Run a build/ship command with INHERITED stdio so
// docker build/push progress streams straight to the terminal (unlike the probe
// edge, which captures a short result). No timeout — a build is long. ok = exit 0;
// execSync throws on a nonzero exit, which we turn into ok:false.
export const runStreamImpl = (cmd) => {
  try {
    execSync(cmd, { stdio: "inherit" });
    return { ok: true };
  } catch (_) {
    return { ok: false };
  }
};
