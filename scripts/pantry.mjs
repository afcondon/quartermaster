#!/usr/bin/env node
// pantry — the shared PureScript dependency larder.
//
// One (package set x compiler) universe, compiled once; every project
// on that set SEEDS its output/ from it with APFS clonefile copies
// (copy-on-write: dep modules are never modified, so they stay shared
// on disk). Proven by spike 2026-07-19: a seeded project compiles
// only its own modules — 1 module / 0.6s vs 498 modules / 7.4s cold —
// because spago normalizes registry source timestamps to epoch, so
// cache-db.json entries are deterministic across projects.
//
//   pantry universe <setVersion>   build/refresh the universe for a set
//                                  (deps = union across afc-work
//                                  projects on that set, or --deps a,b,c)
//   pantry seed <projectDir>       clone the universe into the project's
//                                  output/ (--force to replace existing)
//   pantry status                  list universes and their sizes
//
// The same universe artifact is the seed for Nix derivations later:
// universe-as-derivation, project builds seeded from the store.
import { execSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync, rmSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const PANTRY = process.env.PANTRY_DIR || join(homedir(), ".cache", "ps-pantry");
// the afc-work root: env override, else derived from this script's location
// (<afc-work>/ShapedSteer/quartermaster/scripts/pantry.mjs -> up four).
const AFC_WORK =
  process.env.AFC_WORK ||
  join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "..");

const sh = (cmd, opts = {}) =>
  execSync(cmd, { maxBuffer: 1024 * 1024 * 256, ...opts }).toString();

const pursVersion = () => sh("purs --version").trim();

const universeDir = (set) => join(PANTRY, `${set}-purs-${pursVersion()}`);

// --- reading spago.yaml without a YAML dep: narrow, line-based ------
const readSet = (yaml) => {
  const m = yaml.match(/packageSet:\s*\n\s+registry:\s*([0-9.]+)/);
  return m ? m[1] : null;
};

const readDeps = (yaml) => {
  // core dependencies block: bare names and "name: range" entries
  const m = yaml.match(/^ {2}dependencies:\n((?: {4}- .*\n)+)/m);
  if (!m) return [];
  return m[1]
    .split("\n")
    .map((l) => l.replace(/^ {4}- /, "").trim())
    .filter(Boolean)
    .map((l) => l.split(":")[0].replace(/["']/g, "").trim());
};

const projectsOnSet = (set) => {
  const files = sh(
    `find ${AFC_WORK} -maxdepth 4 -name spago.yaml -not -path "*/node_modules/*" -not -path "*/.spago/*" -not -path "*/GitHub/*" 2>/dev/null`
  ).split("\n").filter(Boolean);
  const out = [];
  for (const f of files) {
    const yaml = readFileSync(f, "utf8");
    if (readSet(yaml) === set) out.push({ file: f, deps: readDeps(yaml) });
  }
  return out;
};

// --- commands -------------------------------------------------------
const universe = (set, extraDeps) => {
  const dir = universeDir(set);
  mkdirSync(dir, { recursive: true });
  let deps;
  if (extraDeps) {
    deps = extraDeps.split(",").map((s) => s.trim()).filter(Boolean);
  } else {
    const projs = projectsOnSet(set);
    deps = [...new Set(projs.flatMap((p) => p.deps))].sort();
    console.log(`union of ${projs.length} projects on ${set}: ${deps.length} packages`);
  }
  // registry deps only: local path-dep names (hylograph-*, warrant, …)
  // can't live in the universe. Rather than hard-code that knowledge,
  // let spago name the strangers ("packages do not exist in your
  // package set") and prune them — a bounded fixpoint, one pass in
  // practice.
  const writeManifest = (ds) =>
    writeFileSync(
      join(dir, "spago.yaml"),
      [
        "package:",
        "  name: pantry-universe",
        "  dependencies:",
        ...ds.map((d) => `    - ${d}`),
        "workspace:",
        "  packageSet:",
        `    registry: ${set}`,
        "",
      ].join("\n")
    );
  mkdirSync(join(dir, "src"), { recursive: true });
  writeFileSync(
    join(dir, "src", "PantryUniverse.purs"),
    "module PantryUniverse where\n\nimport Prelude\n\nuniverse :: Int\nuniverse = 0\n"
  );
  console.log(`building universe ${set} (purs ${pursVersion()}) in ${dir}…`);
  let r;
  for (let attempt = 0; attempt < 4; attempt++) {
    writeManifest(deps);
    r = spawnSync("spago", ["build"], { cwd: dir, encoding: "utf8" });
    const err = (r.stderr || "") + (r.stdout || "");
    if (r.status === 0) break;
    const block = err.match(/packages do not exist in your package set:\n((?:\s+- .*\n)+)/);
    if (!block) {
      process.stderr.write(err);
      process.exit(r.status ?? 1);
    }
    const strangers = block[1]
      .split("\n")
      .map((l) => l.trim().replace(/^- /, "").split(" ")[0])
      .filter(Boolean);
    console.log(`pruning ${strangers.length} non-registry names: ${strangers.join(", ")}`);
    deps = deps.filter((d) => !strangers.includes(d));
  }
  if (r.status !== 0) {
    console.error("universe still failing after pruning; giving up");
    process.exit(1);
  }
  const n = readdirSync(join(dir, "output")).length - 1;
  console.log(`universe ready: ${n} modules in ${join(dir, "output")}`);
};

const seed = (projectDir, force) => {
  const spagoYaml = join(projectDir, "spago.yaml");
  if (!existsSync(spagoYaml)) {
    console.error(`no spago.yaml in ${projectDir}`);
    process.exit(2);
  }
  const set = readSet(readFileSync(spagoYaml, "utf8"));
  if (!set) {
    console.error("project has no workspace.packageSet.registry (solver-mode or purerl?) — nothing to seed from");
    process.exit(2);
  }
  const uni = join(universeDir(set), "output");
  if (!existsSync(uni)) {
    console.error(`no universe for set ${set} + purs ${pursVersion()} — run: pantry universe ${set}`);
    process.exit(2);
  }
  const out = join(projectDir, "output");
  if (existsSync(out)) {
    if (!force) {
      console.error(`${out} exists — pass --force to replace it with a seeded clone`);
      process.exit(2);
    }
    rmSync(out, { recursive: true });
  }
  // APFS clonefile via cp -c: instant, copy-on-write. The universe's
  // own module rides along harmlessly; purs ignores modules it wasn't
  // asked about, and CoW means the disk cost is ~zero.
  sh(`cp -Rc ${JSON.stringify(uni)} ${JSON.stringify(out)}`);
  console.log(`seeded ${out} from universe ${set} (clonefile, ~0 bytes until divergence)`);
};

const status = () => {
  if (!existsSync(PANTRY)) {
    console.log(`no pantry at ${PANTRY} yet`);
    return;
  }
  for (const d of readdirSync(PANTRY)) {
    const out = join(PANTRY, d, "output");
    if (!existsSync(out)) continue;
    const size = sh(`du -sh ${JSON.stringify(out)}`).split("\t")[0].trim();
    const n = readdirSync(out).length - 1;
    console.log(`${d}: ${n} modules, ${size}`);
  }
};

const [cmd, arg, flag] = process.argv.slice(2);
switch (cmd) {
  case "universe":
    if (!arg) { console.error("usage: pantry universe <setVersion> [--deps a,b,c]"); process.exit(2); }
    universe(arg, flag === "--deps" ? process.argv[5] : null);
    break;
  case "seed":
    if (!arg) { console.error("usage: pantry seed <projectDir> [--force]"); process.exit(2); }
    seed(arg, flag === "--force");
    break;
  case "status":
    status();
    break;
  default:
    console.error("usage: pantry universe <set> | seed <dir> [--force] | status");
    process.exit(2);
}
