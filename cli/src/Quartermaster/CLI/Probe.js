import { execSync } from "node:child_process";

// EffectFn1 cmd -> { ok, out }. Run a shell check synchronously (the no-Aff
// seam). ok = exit 0; out = trimmed stdout (empty on failure). Never throws.
export const shProbeImpl = (cmd) => {
  try {
    const out = execSync(cmd, { stdio: ["ignore", "pipe", "ignore"], timeout: 10000 })
      .toString()
      .trim();
    return { ok: true, out };
  } catch (e) {
    return { ok: false, out: ((e.stdout && e.stdout.toString()) || "").trim() };
  }
};
