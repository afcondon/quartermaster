#!/usr/bin/env node
// divergence — what differs between the machines' working copies, and
// between them and GitHub and the PureScript registry. READ-ONLY.
//
// Requirements 1–5 of docs/kb/plans/cross-machine-consistency-requirements.md:
//   1. every git repo: branch, ahead/behind each remote, uncommitted and
//      untracked counts, last commit date, and (in compare) the other machine
//   2. every published package: spago.yaml version, newest tag, registry newest;
//      numbered-but-unpublished versions; descriptions over 300 characters
//   3. repos (per machine) with no remote off the machine
//   4. every `path:` dependency: target, its commit and branch, and whether the
//      other machine has it — "can the other machine build this workspace?"
//   5. every extraPackages pin of our own libraries, with the registry's newest
//
//   divergence snapshot [--fetch] [--root DIR] [--machine NAME] > snap.json
//       Local only, no network (unless --fetch, which runs `git fetch --all`
//       in each repo: that writes remote-tracking refs and nothing else).
//   divergence compare <snap.json> [<other-snap.json>] > report.md
//       Joins one or two snapshots; looks the packages up in the registry
//       (github.com/purescript/registry metadata, never the local
//       registry-index/ cache, which is stale).
//   divergence report [--peer snap.json] [--fetch]
//       snapshot here, then compare with the peer's snapshot if given.
//
// Never merges, commits, checks out, or writes into a repo. `git status` is
// run with GIT_OPTIONAL_LOCKS=0 so it does not even refresh the index.
// Zero dependencies (the spago.yaml subset is parsed here) so it runs on any
// machine straight after a `git pull`.

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { homedir, hostname } from "node:os";
import { dirname, join, relative, resolve, sep } from "node:path";

const SCHEMA = 1;
const HISTORY = 200;          // commits of history kept per branch, for comparing machines
const DESCRIPTION_LIMIT = 300; // spago 1.0.5 cannot read a manifest past this
const SKIP_TOP = ["GitHub/local-copies", "archived"];
const PRUNE = new Set([
  "node_modules", ".spago", "output", "output-es", "target", "_build", ".lake",
  "dist-newstyle", ".stack-work", "__pycache__", ".venv", "venv", ".direnv",
  ".cache", ".next", ".git",
]);

// ---------------------------------------------------------------- utilities

const git = (cwd, args, { timeout = 20000 } = {}) => {
  try {
    return execFileSync("git", args, {
      cwd, encoding: "utf8", timeout, stdio: ["ignore", "pipe", "ignore"],
      env: { ...process.env, GIT_OPTIONAL_LOCKS: "0", GIT_TERMINAL_PROMPT: "0" },
    }).trimEnd();
  } catch { return null; }
};

const parseSemver = (s) => {
  const m = String(s ?? "").match(/^v?(\d+)\.(\d+)\.(\d+)$/);
  return m ? [+m[1], +m[2], +m[3]] : null;
};
const cmpSemver = (a, b) => {
  const x = parseSemver(a), y = parseSemver(b);
  if (!x || !y) return 0;
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] - y[i];
  return 0;
};
const newest = (versions) => versions.filter(parseSemver).sort(cmpSemver).at(-1) ?? null;

const localHostName = () => {
  if (process.platform === "darwin") {
    try { return execFileSync("scutil", ["--get", "LocalHostName"], { encoding: "utf8" }).trim(); } catch {}
  }
  return hostname();
};
const machineName = () => {
  const h = localHostName().toLowerCase().replace(/\.local$/, "");
  if (h.includes("mini")) return "Mini";
  if (h.includes("macbook") || h.includes("mbp")) return "MBP";
  return h;
};

// ------------------------------------------------- a spago.yaml-sized YAML
// Block maps, block lists (of scalars or maps), folded/literal scalars,
// quoted scalars, flow lists/maps of scalars, comments. Enough for spago.yaml.

export function parseYaml(src) {
  const lines = src.split(/\r?\n/);
  let i = 0;
  const isBlank = (l) => /^\s*(#.*)?$/.test(l);
  const ind = (l) => l.match(/^ */)[0].length;
  const isItem = (l) => /^\s*-( |$)/.test(l);
  const stripComment = (s) => {
    let q = null;
    for (let k = 0; k < s.length; k++) {
      const c = s[k];
      if (q) { if (c === q) q = null; continue; }
      if (c === '"' || c === "'") { q = c; continue; }
      if (c === "#" && (k === 0 || /\s/.test(s[k - 1]))) return s.slice(0, k).trimEnd();
    }
    return s.trimEnd();
  };
  const scalar = (raw) => {
    const s = raw.trim();
    if (s === "") return null;
    if ((s[0] === '"' && s.at(-1) === '"') || (s[0] === "'" && s.at(-1) === "'")) return s.slice(1, -1);
    if (s[0] === "[" && s.at(-1) === "]")
      return s.slice(1, -1).split(",").map(scalar).filter((x) => x !== null);
    if (s[0] === "{" && s.at(-1) === "}") {
      const o = {};
      for (const part of s.slice(1, -1).split(",")) {
        const m = part.match(/^\s*([^:]+):\s*(.*)$/);
        if (m) o[scalar(m[1])] = scalar(m[2]);
      }
      return o;
    }
    if (s === "true") return true;
    if (s === "false") return false;
    return s;
  };
  const skip = () => { while (i < lines.length && isBlank(lines[i])) i++; };
  const blockScalar = (style, parentIndent) => {
    const out = [];
    let bi = null;
    while (i < lines.length) {
      const l = lines[i];
      if (/^\s*$/.test(l)) { out.push(""); i++; continue; }
      const n = ind(l);
      if (n <= parentIndent) break;
      if (bi === null) bi = n;
      out.push(l.slice(bi)); i++;
    }
    while (out.length && out.at(-1) === "") out.pop();
    if (style[0] === "|") return out.join("\n");
    let r = "";
    for (const l of out) {
      if (l === "") r += "\n";
      else r += (r === "" || r.endsWith("\n") ? "" : " ") + l;
    }
    return r;
  };
  const parseBlock = (minIndent) => {
    skip();
    if (i >= lines.length) return null;
    const n = ind(lines[i]);
    if (n < minIndent) return null;
    return isItem(lines[i]) ? parseList(n) : parseMap(n);
  };
  const valueAfterKey = (rest, keyIndent) => {
    rest = stripComment(rest ?? "").trim();
    if (rest === "") {
      skip();
      if (i < lines.length) {
        const n = ind(lines[i]);
        if (n > keyIndent || (n === keyIndent && isItem(lines[i]))) return parseBlock(n);
      }
      return null;
    }
    if (/^[>|][-+]?$/.test(rest)) return blockScalar(rest, keyIndent);
    return scalar(rest);
  };
  const KEY = /^([^\s:"'#\[{-][^:]*?|"[^"]*"|'[^']*'):(?:\s+(.*))?$/;
  const parseMap = (n) => {
    const o = {};
    for (;;) {
      skip();
      if (i >= lines.length) break;
      const l = lines[i];
      if (ind(l) !== n || isItem(l)) break;
      const m = l.slice(n).match(KEY);
      if (!m) { i++; continue; }
      i++;
      o[scalar(m[1])] = valueAfterKey(m[2], n);
    }
    return o;
  };
  const parseList = (n) => {
    const a = [];
    for (;;) {
      skip();
      if (i >= lines.length) break;
      const l = lines[i];
      if (ind(l) !== n || !isItem(l)) break;
      const after = l.slice(n + 1);
      const content = after.replace(/^ +/, "");
      const cIndent = n + 1 + (after.length - content.length);
      if (stripComment(content) === "") { i++; a.push(parseBlock(n + 1)); continue; }
      if (KEY.test(stripComment(content))) {
        lines[i] = " ".repeat(cIndent) + content;
        a.push(parseMap(cIndent));
      } else { i++; a.push(scalar(stripComment(content))); }
    }
    return a;
  };
  return parseBlock(0);
}

// ------------------------------------------------------------- remotes

// Matched against remote URLs. Extra patterns (an address, say) can be given
// in DIVERGENCE_MACHINES as "Name=pat1,pat2;Name2=pat3" rather than committed.
const KNOWN_MACHINES = [
  // ssh aliases count too: the MBP reaches the Mini as `macmini:`
  { name: "Mini", patterns: ["mac-mini", "macmini", "/users/andrew/"] },
  { name: "MBP", patterns: ["macbook", "mbp:", "/users/afc/"] },
  { name: "BlackStar", patterns: ["blackstar"] },
];
for (const spec of (process.env.DIVERGENCE_MACHINES ?? "").split(";").filter(Boolean)) {
  const [name, pats = ""] = spec.split("=");
  const m = KNOWN_MACHINES.find((x) => x.name === name) ?? KNOWN_MACHINES[KNOWN_MACHINES.push({ name, patterns: [] }) - 1];
  m.patterns.push(...pats.split(",").map((p) => p.trim().toLowerCase()).filter(Boolean));
}

// Where a remote URL points. `host` is the machine it lives on, if it is one
// of ours; a local path is on this machine.
function classifyRemote(url, self) {
  const u = url.toLowerCase();
  if (u.includes("github.com")) return { kind: "github", offMachine: true };
  if (/\/\/[^/]*\bdc1\b/.test(u) || /:3000\//.test(u)) return { kind: "forgejo", offMachine: true };
  const isPath = u.startsWith("/") || u.startsWith("file:") || u.startsWith(".") || u.startsWith("~");
  for (const m of KNOWN_MACHINES) {
    if (m.patterns.some((p) => u.includes(p))) {
      if (m.name.toLowerCase() === String(self).toLowerCase()) return { kind: "local", offMachine: false };
      // a bare path naming the other machine's home is still a path on this one
      if (isPath) return { kind: "local", offMachine: false };
      return { kind: `machine:${m.name}`, offMachine: m.name !== "MBP" && m.name !== "Mini" };
    }
  }
  if (isPath) return { kind: "local", offMachine: false };
  return { kind: "other", offMachine: true };
}

// ------------------------------------------------------------- the walk

function walk(root) {
  const repos = [], spagos = [];
  const visit = (dir, depth) => {
    const rel = relative(root, dir);
    if (SKIP_TOP.some((s) => rel === s || rel.startsWith(s + sep))) return;
    let entries;
    try { entries = readdirSync(dir, { withFileTypes: true }); } catch { return; }
    if (entries.some((e) => e.name === ".git")) repos.push(dir);
    if (entries.some((e) => e.name === "spago.yaml" && e.isFile())) spagos.push(join(dir, "spago.yaml"));
    if (depth >= 8) return;
    for (const e of entries) {
      if (!e.isDirectory() || PRUNE.has(e.name) || e.name.startsWith("output-")) continue;
      visit(join(dir, e.name), depth + 1);
    }
  };
  visit(root, 0);
  return { repos: repos.sort(), spagos: spagos.sort() };
}

const containingRepo = (repoPaths, p) => {
  let best = null;
  for (const r of repoPaths) if ((p === r || p.startsWith(r + sep)) && (!best || r.length > best.length)) best = r;
  return best;
};

// ------------------------------------------------------------- one repo

function snapshotRepo(dir, root, self, allRepos, doFetch) {
  const rel = relative(root, dir) || ".";
  const r = { path: rel };
  if (doFetch) r.fetchOk = git(dir, ["fetch", "--all", "--quiet", "--no-write-fetch-head"], { timeout: 60000 }) !== null;

  const gitFile = join(dir, ".git");
  r.worktree = existsSync(gitFile) && statSync(gitFile).isFile();
  const parent = containingRepo(allRepos.filter((p) => p !== dir), dir);
  if (parent) {
    r.nestedIn = relative(root, parent) || ".";
    const sub = relative(parent, dir);
    const ls = git(parent, ["ls-files", "--stage", "--", sub]);
    r.submodule = !!ls && ls.startsWith("160000");
    r.ignoredByParent = git(parent, ["check-ignore", "-q", sub]) !== null;
  }

  const head = git(dir, ["rev-parse", "HEAD"]);
  if (!head) { r.empty = true; return r; }
  r.head = head;
  const branch = git(dir, ["symbolic-ref", "--short", "-q", "HEAD"]);
  r.branch = branch || null;
  r.detached = !branch;
  r.lastCommit = git(dir, ["log", "-1", "--format=%cI"]);

  const status = git(dir, ["status", "--porcelain=v1", "--untracked-files=normal"]) ?? "";
  const lines = status ? status.split("\n") : [];
  r.untracked = lines.filter((l) => l.startsWith("??")).length;
  r.uncommitted = lines.length - r.untracked;

  // remotes
  const rv = git(dir, ["remote", "-v"]) ?? "";
  const remotes = new Map();
  for (const l of rv.split("\n")) {
    const m = l.match(/^(\S+)\s+(\S+)\s+\(fetch\)$/);
    if (m) remotes.set(m[1], { name: m[1], url: m[2], ...classifyRemote(m[2], self) });
  }
  r.remotes = [...remotes.values()];
  const offRemotes = r.remotes.filter((x) => x.offMachine).map((x) => x.name);
  r.offMachineRemotes = offRemotes;

  // freshness of what we know about remotes: newest mtime under refs/remotes or FETCH_HEAD
  const gitDir = git(dir, ["rev-parse", "--git-common-dir"]);
  if (gitDir) {
    const gd = resolve(dir, gitDir);
    let t = 0;
    for (const f of ["FETCH_HEAD", "packed-refs"]) {
      try { t = Math.max(t, statSync(join(gd, f)).mtimeMs); } catch {}
    }
    try { t = Math.max(t, statSync(join(gd, "refs", "remotes")).mtimeMs); } catch {}
    r.lastFetch = t ? new Date(t).toISOString() : null;
  }

  // HEAD against each remote: the upstream if it is on that remote, else the
  // remote's branch of the same name. A branch with neither is not compared
  // (comparing it with the remote's default branch reads as false "behind");
  // its commits show up as unpushed instead.
  const upstream = branch ? git(dir, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"]) : null;
  r.perRemote = [];
  for (const rem of r.remotes) {
    let ref = upstream && upstream.startsWith(rem.name + "/") ? `refs/remotes/${upstream}` : branch ? `refs/remotes/${rem.name}/${branch}` : null;
    if (ref && git(dir, ["rev-parse", "-q", "--verify", ref]) === null) ref = null;
    if (!ref) { r.perRemote.push({ remote: rem.name, against: null }); continue; }
    const c = git(dir, ["rev-list", "--left-right", "--count", `HEAD...${ref}`]);
    const [ahead, behind] = c ? c.split(/\s+/).map(Number) : [null, null];
    r.perRemote.push({ remote: rem.name, against: ref.replace("refs/remotes/", ""), ahead, behind });
  }

  // every local branch: tip, upstream, commits on no off-machine remote, history
  const fe = git(dir, ["for-each-ref", "--format=%(refname:short)%09%(objectname)%09%(upstream:short)%09%(committerdate:iso-strict)", "refs/heads"]) ?? "";
  const notRemotes = offRemotes.map((n) => `--remotes=${n}`);
  r.branches = [];
  for (const l of fe.split("\n").filter(Boolean)) {
    const [name, sha, upstream, date] = l.split("\t");
    const unpushed = Number(git(dir, ["rev-list", "--count", sha, ...(notRemotes.length ? ["--not", ...notRemotes] : [])]) ?? NaN);
    const history = (git(dir, ["rev-list", `--max-count=${HISTORY}`, sha]) ?? "").split("\n").filter(Boolean).map((s) => s.slice(0, 12));
    r.branches.push({ name, sha, upstream: upstream || null, date, unpushed, history });
  }

  const tags = git(dir, ["tag", "--list"]) ?? "";
  r.tags = tags.split("\n").filter(Boolean);
  return r;
}

// ------------------------------------------------------------- spago.yaml

function snapshotSpago(file, root, repoPaths) {
  const rel = relative(root, file);
  const s = { path: rel };
  let y;
  try { y = parseYaml(readFileSync(file, "utf8")) ?? {}; } catch (e) { s.error = String(e); return s; }
  const repo = containingRepo(repoPaths, dirname(file));
  s.repo = repo ? relative(root, repo) || "." : null;

  const p = y.package;
  if (p && typeof p === "object") {
    const pub = p.publish && typeof p.publish === "object" ? p.publish : null;
    const desc = typeof p.description === "string" ? p.description : null;
    s.package = {
      name: p.name ?? null,
      version: pub?.version ?? null,
      published: !!pub,
      location: pub?.location ?? null,
      descriptionLength: desc ? desc.length : 0,
    };
  }

  const w = y.workspace;
  if (w && typeof w === "object") {
    const ps = w.packageSet ?? {};
    s.workspace = { packageSet: ps.registry ?? ps.url ?? null, extraPackages: [] };
    const extra = w.extraPackages && typeof w.extraPackages === "object" ? w.extraPackages : {};
    for (const [name, v] of Object.entries(extra)) {
      if (typeof v === "string") { s.workspace.extraPackages.push({ name, kind: "version", version: v }); continue; }
      if (!v || typeof v !== "object") continue;
      if (v.path) {
        const abs = resolve(dirname(file), String(v.path).replace(/^~(?=\/)/, homedir()));
        const inRoot = abs === root || abs.startsWith(root + sep);
        const exists = existsSync(abs);
        const tRepo = exists ? containingRepo(repoPaths, abs) : null;
        s.workspace.extraPackages.push({
          name, kind: "path", path: v.path,
          target: inRoot ? relative(root, abs) : abs,
          outsideRoot: !inRoot,
          exists,
          hasSpago: exists && existsSync(join(abs, "spago.yaml")),
          repo: tRepo ? relative(root, tRepo) || "." : null,
        });
      } else if (v.git) {
        s.workspace.extraPackages.push({ name, kind: "git", git: v.git, ref: v.ref ?? null, subdir: v.subdir ?? null });
      } else if (v.version) {
        s.workspace.extraPackages.push({ name, kind: "version", version: String(v.version) });
      } else {
        s.workspace.extraPackages.push({ name, kind: "other", raw: v });
      }
    }
  }
  return s;
}

function snapshot({ root, machine, doFetch }) {
  const self = machine ?? machineName();
  const { repos, spagos } = walk(root);
  const out = {
    schema: SCHEMA, machine: self, host: localHostName(), root, takenAt: new Date().toISOString(),
    fetched: !!doFetch, repos: [], spago: [],
  };
  for (const d of repos) out.repos.push(snapshotRepo(d, root, self, repos, doFetch));
  for (const f of spagos) out.spago.push(snapshotSpago(f, root, repos));
  return out;
}

// ------------------------------------------------------------- registry

async function registryLookup(names) {
  const res = new Map();
  const queue = [...new Set(names)];
  const worker = async () => {
    while (queue.length) {
      const n = queue.shift();
      try {
        const r = await fetch(`https://raw.githubusercontent.com/purescript/registry/main/metadata/${n}.json`);
        if (r.status === 404) { res.set(n, { found: false }); continue; }
        if (!r.ok) { res.set(n, { error: `HTTP ${r.status}` }); continue; }
        const j = await r.json();
        const versions = Object.keys(j.published ?? {});
        res.set(n, {
          found: true, versions, newest: newest(versions),
          owner: j.location?.githubOwner ?? null, repo: j.location?.githubRepo ?? null,
          unpublished: Object.keys(j.unpublished ?? {}),
        });
      } catch (e) { res.set(n, { error: String(e.message ?? e) }); }
    }
  };
  await Promise.all(Array.from({ length: 8 }, worker));
  return res;
}

// ------------------------------------------------------------- comparison

const short = (s) => (s ? s.slice(0, 7) : "—");
const day = (iso) => (iso ? iso.slice(0, 10) : "—");
const ageDays = (iso, now) => (iso ? Math.floor((now - Date.parse(iso)) / 86400000) : null);
const md = (s) => String(s ?? "").replace(/\|/g, "\\|");

// distance between two branch tips from their recorded histories
function apart(a, b) {
  if (!a || !b) return null;
  if (a.sha === b.sha) return { same: true };
  const setB = new Map(b.history.map((s, i) => [s, i]));
  for (let ia = 0; ia < a.history.length; ia++) {
    const ib = setB.get(a.history[ia]);
    if (ib !== undefined) return { aAhead: ia, bAhead: ib };
  }
  return { unknown: true };
}

function describeApart(d, A, B) {
  if (!d) return "";
  if (d.same) return "same";
  if (d.unknown) return `no common commit in last ${HISTORY}`;
  const parts = [];
  if (d.aAhead) parts.push(`${A} +${d.aAhead}`);
  if (d.bAhead) parts.push(`${B} +${d.bAhead}`);
  return parts.join(", ") + (d.aAhead && d.bAhead ? " (diverged)" : "");
}

function repoCell(r) {
  if (!r) return "absent";
  if (r.empty) return "no commits";
  const bits = [r.detached ? `detached ${short(r.head)}` : `\`${r.branch}\``];
  for (const p of r.perRemote) {
    if (!p.against) continue;
    if (p.ahead || p.behind) bits.push(`${p.remote} ${p.ahead ? "+" + p.ahead : ""}${p.ahead && p.behind ? "/" : ""}${p.behind ? "−" + p.behind : ""}`);
  }
  if (!r.remotes.length) bits.push("**no remote**");
  else if (!r.offMachineRemotes.length) bits.push("**no off-machine remote**");
  else {
    const cur = r.branches.find((b) => b.name === r.branch);
    if (cur?.unpushed && !r.perRemote.some((p) => p.ahead)) bits.push(`${cur.unpushed} on no off-machine remote`);
  }
  if (r.uncommitted) bits.push(`${r.uncommitted} changed`);
  if (r.untracked) bits.push(`${r.untracked} untracked`);
  const stranded = r.branches.filter((b) => b.name !== r.branch && b.unpushed > 0 && r.offMachineRemotes.length);
  if (stranded.length) bits.push(`other branches unpushed: ${stranded.map((b) => `${b.name} (${b.unpushed})`).join(", ")}`);
  return bits.join(" · ");
}

const isNoise = (r) => r.submodule || r.ignoredByParent;
const interesting = (r) => r && !r.empty && (
  r.perRemote.some((p) => p.ahead || p.behind) || r.uncommitted || r.untracked ||
  !r.offMachineRemotes.length ||
  r.branches.some((b) => b.unpushed > 0 && r.offMachineRemotes.length));

async function compare(snaps) {
  const now = Date.now();
  const [A, B] = snaps;
  const names = snaps.map((s) => s.machine);
  const L = [];
  const push = (...xs) => L.push(...xs);

  // ---- index repos by path, falling back to remote URL for moved checkouts
  const byPath = snaps.map((s) => new Map(s.repos.map((r) => [r.path, r])));
  const keys = [...new Set(snaps.flatMap((s) => s.repos.filter((r) => !isNoise(r)).map((r) => r.path)))].sort();

  // ---- registry
  const published = snaps.flatMap((s) => s.spago.filter((x) => x.package?.published && x.package.name).map((x) => x.package.name));
  const pinned = snaps.flatMap((s) => s.spago.flatMap((x) => x.workspace?.extraPackages ?? []).map((e) => e.name));
  const reg = await registryLookup([...published, ...pinned]);
  const own = new Set(published);
  for (const [n, v] of reg) if (v.owner === "afcondon") own.add(n);

  // ---- section 1 data
  const rows = [];
  for (const k of keys) {
    const rs = byPath.map((m) => m.get(k));
    const cross = rs.length === 2 && rs[0] && rs[1] && !rs[0].empty && !rs[1].empty ? (() => {
      const ba = rs[0].branches.find((b) => b.name === rs[0].branch);
      const bb = rs[1].branches.find((b) => b.name === rs[1].branch);
      const sameName = rs[0].branch === rs[1].branch;
      const d = apart(ba ?? { sha: rs[0].head, history: [] }, bb ?? { sha: rs[1].head, history: [] });
      return { sameName, d, text: (sameName ? "" : `branches differ (${rs[0].branch ?? "detached"} / ${rs[1].branch ?? "detached"}); `) + describeApart(d, names[0], names[1]) };
    })() : null;
    const differs = cross && !(cross.sameName && cross.d?.same);
    const missing = rs.length === 2 && (!rs[0] || !rs[1]);
    rows.push({ k, rs, cross, show: rs.some(interesting) || differs || missing, differs, missing });
  }

  // ---- headline
  push(`# Divergence report — ${new Date(now).toISOString().slice(0, 10)}`, "");
  push(`Generated by \`ShapedSteer/quartermaster/scripts/divergence.mjs\`. Read-only.`, "");
  for (const s of snaps) {
    const fetchAges = s.repos.map((r) => ageDays(r.lastFetch, Date.parse(s.takenAt))).filter((x) => x !== null);
    const med = fetchAges.sort((a, b) => a - b)[Math.floor(fetchAges.length / 2)];
    push(`- **${s.machine}** (\`${s.host}\`, root \`${s.root}\`): snapshot ${s.takenAt.slice(0, 16).replace("T", " ")}Z, ` +
      (s.fetched ? "remotes fetched first." : `**not fetched** — remote counts are as of each repo's last fetch (median ${med ?? "?"} days old).`));
  }
  push("");

  const H = [];
  for (const [i, s] of snaps.entries()) {
    const rs = s.repos.filter((r) => !isNoise(r) && !r.empty);
    const curUnpushed = (r) => r.branches.find((b) => b.name === r.branch)?.unpushed || 0;
    const aheadOff = rs.filter((r) => r.offMachineRemotes.length && curUnpushed(r) > 0);
    const dirty = rs.filter((r) => r.uncommitted);
    const untr = rs.filter((r) => r.untracked);
    const noOff = rs.filter((r) => !r.offMachineRemotes.length);
    const stranded = rs.filter((r) => r.offMachineRemotes.length && r.branches.some((b) => b.name !== r.branch && b.unpushed > 0));
    H.push(`- **${s.machine}**: ${rs.length} repositories. ` +
      `${aheadOff.length} whose checked-out branch has commits on no off-machine remote (${aheadOff.reduce((n, r) => n + curUnpushed(r), 0)} commits); ` +
      `${stranded.length} more with another branch in that state; ` +
      `${dirty.length} with uncommitted changes (${dirty.reduce((n, r) => n + r.uncommitted, 0)} files), ${untr.length} with untracked files; ` +
      `${noOff.length} with no remote off the machine at all.`);
  }
  if (snaps.length === 2) {
    const both = rows.filter((r) => r.rs[0] && r.rs[1]);
    H.push(`- **Between machines**: ${both.length} repositories on both, ${rows.filter((r) => r.rs[0] && !r.rs[1]).length} only on ${names[0]}, ` +
      `${rows.filter((r) => !r.rs[0] && r.rs[1]).length} only on ${names[1]}; ${both.filter((r) => r.differs).length} differ in branch or commit.`);
  }
  const pkgFindings = []; // filled below, counted in headline
  const L1 = L.length;

  // ---- 1. repositories
  const sec1 = [];
  sec1.push("## 1. Repositories", "");
  sec1.push(`Only repositories with something to say: ahead of or behind a remote, uncommitted or untracked files, ` +
    `no remote off the machine, a branch whose commits are on no off-machine remote` +
    (snaps.length === 2 ? `, or a difference between the machines.` : "."), "");
  const head1 = ["Repository", ...names.map((n) => n)];
  if (snaps.length === 2) head1.push("Between machines");
  head1.push("Last commit");
  sec1.push(`| ${head1.join(" | ")} |`, `|${head1.map(() => "---").join("|")}|`);
  for (const row of rows.filter((r) => r.show)) {
    const cells = [`\`${row.k}\``, ...row.rs.map((r) => md(repoCell(r)))];
    if (snaps.length === 2) cells.push(md(row.missing ? `only on ${row.rs[0] ? names[0] : names[1]}` : row.cross?.text ?? ""));
    cells.push(row.rs.map((r) => day(r?.lastCommit)).join(" / "));
    sec1.push(`| ${cells.join(" | ")} |`);
  }
  const quiet = rows.filter((r) => !r.show).map((r) => r.k);
  sec1.push("", `${quiet.length} more with nothing to report: ${quiet.map((k) => `\`${k}\``).join(", ") || "none"}.`, "");
  const noise = [...new Set(snaps.flatMap((s) => s.repos.filter(isNoise).map((r) => r.path)))];
  if (noise.length) sec1.push(`Not counted (submodules, or nested checkouts their parent ignores): ${noise.map((k) => `\`${k}\``).join(", ")}.`, "");

  // ---- 3. no remote off the machine
  const sec3 = ["## 3. No remote off the machine", "",
    "Per machine. A remote that is only the other machine counts as none.", ""];
  for (const s of snaps) {
    const rs = s.repos.filter((r) => !isNoise(r) && !r.offMachineRemotes.length);
    sec3.push(`**${s.machine}** (${rs.length}):`, "");
    if (!rs.length) sec3.push("- none");
    for (const r of rs) {
      const how = r.remotes.length ? `remotes: ${r.remotes.map((x) => `${x.name} → ${x.kind}`).join(", ")}` : "no remote at all";
      const n = r.branches?.reduce((m, b) => Math.max(m, b.unpushed || 0), 0);
      sec3.push(`- \`${r.path}\` — ${how}${r.empty ? " (no commits)" : `; ${n} commits, none off the machine; last ${day(r.lastCommit)}`}`);
    }
    sec3.push("");
  }

  // ---- 2. packages
  const sec2 = ["## 2. Published packages", "",
    "Every `spago.yaml` with a `publish:` block. Registry = `purescript/registry` metadata on GitHub.", ""];
  const pkgRows = new Map();
  for (const s of snaps) for (const x of s.spago) {
    if (!x.package?.published || !x.package.name) continue;
    const key = x.package.name;
    if (!pkgRows.has(key)) pkgRows.set(key, { name: key, per: {} });
    const repo = s.repos.find((r) => r.path === x.repo);
    const prefixRe = new RegExp(`^(?:${key}[-/@])?v?(\\d+\\.\\d+\\.\\d+)$`);
    const tagVersions = (repo?.tags ?? []).map((t) => t.match(prefixRe)?.[1]).filter(Boolean);
    const list = pkgRows.get(key).per[s.machine] ??= [];
    list.push({ path: x.path, version: x.package.version, descLen: x.package.descriptionLength,
      newestTag: newest(tagVersions), tagged: x.package.version ? tagVersions.includes(x.package.version.replace(/^v/, "")) : false });
  }
  const h2 = ["Package", "Registry newest", ...names, "Flags"];
  sec2.push(`| ${h2.join(" | ")} |`, `|${h2.map(() => "---").join("|")}|`);
  const flaggedPkgs = [];
  for (const p of [...pkgRows.values()].sort((a, b) => a.name.localeCompare(b.name))) {
    const g = reg.get(p.name) ?? {};
    const regNewest = g.found ? g.newest : g.error ? `? (${g.error})` : "not in registry";
    const flags = new Set();
    const cells = names.map((n) => (p.per[n] ?? []).map((e) => {
      const v = e.version ?? "?";
      if (g.found && e.version && !g.versions.includes(e.version)) {
        if (cmpSemver(e.version, g.newest) > 0) flags.add(`${v} numbered, not published`);
        else flags.add(`${v} not in registry`);
      }
      if (g.found && e.version && cmpSemver(e.version, g.newest) < 0) flags.add(`${n}'s \`${e.path}\` behind registry`);
      if (!g.found && !g.error) flags.add("never published");
      if (e.version && !e.tagged) flags.add(`no tag for ${v} on ${n}`);
      if (e.descLen > DESCRIPTION_LIMIT) flags.add(`**description ${e.descLen} chars (> ${DESCRIPTION_LIMIT})**`);
      return `${v} (tag ${e.newestTag ?? "none"})${(p.per[n] ?? []).length > 1 ? ` in \`${e.path}\`` : ""}`;
    }).join("<br>") || "—");
    if (names.length === 2 && p.per[names[0]] && p.per[names[1]]) {
      const va = new Set(p.per[names[0]].map((e) => e.version)), vb = new Set(p.per[names[1]].map((e) => e.version));
      if ([...va].some((v) => !vb.has(v))) flags.add("versions differ between machines");
    }
    if ([...flags].some((f) => /numbered|description/.test(f))) flaggedPkgs.push(p.name);
    sec2.push(`| \`${p.name}\` | ${md(regNewest)} | ${cells.map(md).join(" | ")} | ${md([...flags].join("; "))} |`);
  }
  sec2.push("");

  // ---- 4. path dependencies
  const sec4 = ["## 4. Path dependencies", "",
    "Per workspace (a `spago.yaml` with `workspace:`), every `extraPackages` entry taken by `path:` " +
    "into another repository (a path inside the workspace's own repository cannot diverge from it). " +
    (snaps.length === 2 ? "Tables only for workspaces with something to say; the rest are listed after." : ""), ""];
  const cannot = [];
  for (const [si, s] of snaps.entries()) {
    const other = snaps[1 - si];
    const crossRepo = (w) => w.workspace.extraPackages.filter((e) => e.kind === "path" && (e.repo === null || e.repo !== w.repo));
    const ws = s.spago.filter((x) => x.workspace && crossRepo(x).length);
    if (!ws.length) continue;
    sec4.push(`### Workspaces on ${s.machine} (${ws.length} with path dependencies into other repositories)`, "");
    const fine = [];
    for (const w of ws) {
      const deps = crossRepo(w);
      const otherW = other?.spago.find((x) => x.path === w.path);
      // each dependency is counted once per list
      const missingHere = [], noRepoHere = [], dirtyHere = [], absentThere = [], unknownThere = [], differsThere = [];
      const lines = [];
      for (const e of deps) {
        const repo = e.repo ? s.repos.find((r) => r.path === e.repo) : null;
        const here = !e.exists ? "**missing here**" :
          repo ? `\`${e.repo}\` @ ${repo.branch ? "`" + repo.branch + "`" : "detached"} ${short(repo.head)}${repo.uncommitted ? ` +${repo.uncommitted} changed` : ""}` :
          "**in no repository**";
        if (!e.exists) missingHere.push(e.name);
        else if (!repo) noRepoHere.push(e.name);
        else if (repo.uncommitted) dirtyHere.push(e.name);
        let there = "";
        if (other) {
          const oSpago = otherW?.workspace?.extraPackages.find((x) => x.name === e.name && x.kind === "path");
          const oRepo = e.repo ? other.repos.find((r) => r.path === e.repo) : null;
          const targetKnown = oSpago ? oSpago.exists : !!(oRepo || other.spago.some((x) => x.path === join(e.target, "spago.yaml")));
          if (e.outsideRoot) { there = "outside the workspace root: unknown"; unknownThere.push(e.name); }
          else if (!targetKnown) { there = "**absent**"; if (e.exists) absentThere.push(e.name); }
          else if (repo && oRepo) {
            const ba = repo.branches.find((b) => b.name === repo.branch) ?? { sha: repo.head, history: [] };
            const bb = oRepo.branches.find((b) => b.name === oRepo.branch) ?? { sha: oRepo.head, history: [] };
            const d = apart(ba, bb);
            there = d?.same && repo.branch === oRepo.branch ? "same commit" :
              `${oRepo.branch ? "`" + oRepo.branch + "`" : "detached"} ${short(oRepo.head)} — ${describeApart(d, s.machine, other.machine)}`;
            if (!d?.same) differsThere.push(e.name);
            if (oRepo.uncommitted) there += ` +${oRepo.uncommitted} changed`;
          } else there = "present";
        }
        lines.push(`| \`${e.name}\` | \`${md(e.target)}\` | ${md(here)} |${other ? ` ${md(there)} |` : ""}`);
      }
      const notes = [];
      if (other) {
        if (absentThere.length) notes.push(`**${other.machine} cannot build this as it stands**: ${absentThere.length} of ${deps.length} present here are absent there (${absentThere.join(", ")}).`);
        else if (differsThere.length) notes.push(`${other.machine} can build it, against different commits of ${differsThere.join(", ")}.`);
        else notes.push(`${other.machine} can build it${unknownThere.length ? "" : ", against the same commits"}.`);
        if (unknownThere.length) notes.push(`Outside the root, not checked on ${other.machine}: ${unknownThere.join(", ")}.`);
      }
      if (missingHere.length) notes.push(`**Not buildable on ${s.machine}**: ${missingHere.length} missing here (${missingHere.join(", ")}).`);
      if (noRepoHere.length) notes.push(`In no repository: ${noRepoHere.join(", ")}.`);
      if (dirtyHere.length) notes.push(`Built against uncommitted changes here: ${dirtyHere.join(", ")}.`);
      if (absentThere.length && otherW) cannot.push(`\`${w.path}\` (${s.machine}→${other.machine}: ${absentThere.length} of ${deps.length} absent)`);
      if (other && !otherW) notes.unshift(`(The workspace itself is not on ${other.machine}.)`);
      if (!notes.length || (notes.length === 1 && other && !absentThere.length && !differsThere.length && !unknownThere.length)) {
        fine.push(`\`${w.path}\` (${deps.length})`); continue;
      }
      sec4.push(`**\`${w.path}\`** — ${deps.length} path dependencies into other repositories. ${notes.join(" ")}`, "");
      sec4.push(`| Package | Target | On ${s.machine} |${other ? ` On ${other.machine} |` : ""}`, `|---|---|---|${other ? "---|" : ""}`);
      sec4.push(...lines, "");
    }
    if (fine.length) sec4.push(`Nothing to report (${fine.length}: ${other ? `same commits on ${other.machine}` : "all present, clean, in a repository"}): ${fine.join(", ")}.`, "");
  }

  // ---- 5. pins
  const sec5 = ["## 5. Pins of our own libraries", "",
    "Every `extraPackages` entry, across all workspaces, naming one of our libraries " +
    "(published by a `spago.yaml` here, or owned by `afcondon` in the registry), grouped by what it pins.", ""];
  const pins = new Map();
  for (const s of snaps) for (const x of s.spago) for (const e of x.workspace?.extraPackages ?? []) {
    if (!own.has(e.name)) continue;
    const how = e.kind === "version" ? e.version : e.kind === "git" ? `git ${e.ref ?? "HEAD"}` : e.kind === "path" ? `path \`${e.target}\`` : e.kind;
    const key = `${e.name}\u0000${how}`;
    if (!pins.has(key)) pins.set(key, { name: e.name, how, kind: e.kind, where: new Map() });
    const w = pins.get(key).where;
    if (!w.has(x.path)) w.set(x.path, new Set());
    w.get(x.path).add(s.machine);
  }
  const h5 = ["Library", "Registry newest", "Pinned as", "Status", "Workspaces"];
  sec5.push(`| ${h5.join(" | ")} |`, `|${h5.map(() => "---").join("|")}|`);
  const stalePins = [];
  for (const p of [...pins.values()].sort((a, b) => a.name.localeCompare(b.name) || a.how.localeCompare(b.how))) {
    const g = reg.get(p.name) ?? {};
    let status = "";
    if (p.kind === "version") {
      if (!g.found) status = "not in registry";
      else if (!g.versions.includes(p.how.replace(/^v/, ""))) status = "**version not in registry**";
      else if (cmpSemver(p.how, g.newest) < 0) { status = `behind (${g.newest} out)`; stalePins.push(p); }
      else status = "newest";
    } else if (p.kind === "path") status = g.found ? "by path" : "by path; never published";
    else status = p.kind;
    const ws = [...p.where].map(([path, ms]) => `\`${path}\`${snaps.length === 2 && ms.size === 1 ? ` (${[...ms][0]} only)` : ""}`);
    sec5.push(`| \`${p.name}\` | ${md(g.found ? g.newest : "—")} | ${md(p.how)} | ${md(status)} | ${md(ws.length > 4 ? `${ws.length} workspaces: ${ws.join(", ")}` : ws.join(", "))} |`);
  }
  sec5.push("");

  H.push(`- **Packages**: ${pkgRows.size} published; flagged (numbered-unpublished or long description): ${flaggedPkgs.length ? flaggedPkgs.map((n) => `\`${n}\``).join(", ") : "none"}.`);
  if (snaps.length === 2) H.push(`- **Workspaces on both machines that one of them cannot build**: ${cannot.length}${cannot.length ? " — " + cannot.join("; ") : ""}. ` +
    `(Workspaces present on only one machine are in section 4, marked, not counted here.)`);
  H.push(`- **Pins**: ${pins.size} distinct pins of our own libraries; ${stalePins.length} behind the registry's newest.`);
  const unfetched = snaps.filter((s) => !s.fetched).map((s) => s.machine);
  if (unfetched.length) {
    H.unshift(`> **Not fetched: ${unfetched.join(", ")}.** Ahead/behind GitHub for ${unfetched.length > 1 ? "these machines" : "that machine"} is as of each repo's last fetch, ` +
      `so "behind" is mostly invisible. For a current report, take the snapshot with \`--fetch\`.`, "");
    process.stderr.write(`divergence: snapshot(s) not fetched: ${unfetched.join(", ")}; remote counts are stale. Re-run with --fetch for current ones.\n`);
  }
  push("## Headline", "", ...H, "");
  push(...sec1, ...sec2, ...sec3, ...sec4, ...sec5);
  return L.join("\n");
}

// ------------------------------------------------------------- CLI

function argv() {
  const [cmd, ...rest] = process.argv.slice(2);
  const opts = { _: [] };
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (a === "--fetch") opts.fetch = true;
    else if (a === "--root") opts.root = rest[++i];
    else if (a === "--machine") opts.machine = rest[++i];
    else if (a === "--peer") opts.peer = rest[++i];
    else opts._.push(a);
  }
  return { cmd, opts };
}

const defaultRoot = () => process.env.AFC_WORK || join(homedir(), "work", "afc-work");
const load = (f) => {
  const s = JSON.parse(readFileSync(f, "utf8"));
  if (s.schema !== SCHEMA) throw new Error(`${f}: snapshot schema ${s.schema}, expected ${SCHEMA}`);
  // Classify remotes with this copy's rules, so an older snapshot is read the
  // same way as a new one. (Per-branch unpushed counts were computed when the
  // snapshot was taken and can't be redone here.)
  for (const r of s.repos) {
    if (!r.remotes) continue;
    r.remotes = r.remotes.map((x) => ({ ...x, ...classifyRemote(x.url, s.machine) }));
    r.offMachineRemotes = r.remotes.filter((x) => x.offMachine).map((x) => x.name);
  }
  return s;
};

const { cmd, opts } = argv();
if (cmd === "snapshot") {
  process.stdout.write(JSON.stringify(snapshot({ root: resolve(opts.root ?? defaultRoot()), machine: opts.machine, doFetch: opts.fetch })) + "\n");
} else if (cmd === "compare" && opts._.length >= 1 && opts._.length <= 2) {
  process.stdout.write(await compare(opts._.map(load)) + "\n");
} else if (cmd === "report") {
  const here = snapshot({ root: resolve(opts.root ?? defaultRoot()), machine: opts.machine, doFetch: opts.fetch });
  process.stdout.write(await compare(opts.peer ? [here, load(opts.peer)] : [here]) + "\n");
} else {
  process.stderr.write(`usage:
  divergence snapshot [--fetch] [--root DIR] [--machine NAME] > snap.json
  divergence compare <snap.json> [<other-snap.json>] > report.md
  divergence report [--peer other-snap.json] [--fetch] > report.md

  --fetch is off by default (the report is read-only), but without it the
  remote counts are as of each repo's last fetch. Use it for a current report.
`);
  process.exit(2);
}
