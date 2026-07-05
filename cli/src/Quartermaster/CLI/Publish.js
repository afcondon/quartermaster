import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// EffectFn1 cmd -> { ok }. Run a publish command with INHERITED stdio so
// wrangler's upload progress streams straight to the terminal (unlike the probe
// edge, which captures a short result). No timeout — an upload is long. ok = exit
// 0; execSync throws on a nonzero exit, which we turn into ok:false.
export const runStreamImpl = (cmd) => {
  try {
    execSync(cmd, { stdio: "inherit" });
    return { ok: true };
  } catch (_) {
    return { ok: false };
  }
};

const CF_API = "https://api.cloudflare.com/client/v4";

const post = (url, body, tokenEnvName, env) =>
  JSON.parse(execSync(
    `curl -s -X POST -H "Authorization: Bearer $${tokenEnvName}" -H "Content-Type: application/json" ${url} --data '${body}'`,
    { encoding: "utf8", env },
  ));
const getj = (url, tokenEnvName, env) =>
  JSON.parse(execSync(`curl -s -H "Authorization: Bearer $${tokenEnvName}" ${url}`, { encoding: "utf8", env }));

// EffectFn2 (project, domain) -> { ok, message }. Make the custom domain live in
// two parts, each with the RIGHT credential:
//   1. Attach the domain to the Pages project — `pages:write`, which wrangler's
//      stored OAuth token has (the ambient auth the deploy just used).
//   2. Create the zone CNAME (<sub> -> <project>.pages.dev, proxied) — needs
//      `Zone:DNS:Edit`, which the OAuth token does NOT have. Use a scoped
//      CLOUDFLARE_API_TOKEN if present (the CF peer of `docker login` host prep);
//      otherwise report the exact record to add. Without the DNS record the
//      attach stays `pending`, so we say so rather than claim success.
// Synchronous (curl via execSync) to fit EffectFn; tokens go via env, never the
// command string. Non-fatal throughout — the deploy is the real verdict.
export const ensureCustomDomainImpl = (project, domain) => {
  try {
    const cfg = readFileSync(join(homedir(), ".wrangler", "config", "default.toml"), "utf8");
    const m = cfg.match(/oauth_token\s*=\s*"([^"]+)"/);
    if (!m) return { ok: false, message: "no wrangler oauth_token found — run `wrangler login`" };
    const oauthEnv = { ...process.env, CF_TOKEN: m[1] };

    const acct = getj(`${CF_API}/accounts`, "CF_TOKEN", oauthEnv)?.result?.[0]?.id;
    if (!acct) return { ok: false, message: "could not resolve CF account id" };

    // 1. attach (idempotent)
    const attach = post(`${CF_API}/accounts/${acct}/pages/projects/${project}/domains`,
      `{"name":"${domain}"}`, "CF_TOKEN", oauthEnv);
    const attachMsg = attach?.success ? "attached" : (attach?.errors?.[0]?.message || "attach failed");
    const attachedOk = attach?.success || /already|exists/i.test(attachMsg);

    // 2. DNS record (Zone:DNS:Edit — needs a scoped CLOUDFLARE_API_TOKEN)
    const labels = domain.split(".");
    const zoneName = labels.slice(-2).join(".");
    const sub = labels.slice(0, -2).join(".") || "@";
    const target = `${project}.pages.dev`;
    // Dedicated var — NOT CLOUDFLARE_API_TOKEN, which wrangler would hijack for
    // the deploy (and a DNS-only token can't list accounts). Keeps wrangler on
    // its OAuth login and this scoped token for DNS only.
    const dnsToken = process.env.QM_CF_DNS_TOKEN;
    if (!dnsToken) {
      return {
        ok: attachedOk,
        message: `${attachMsg} (pending) — DNS not created: the wrangler OAuth token lacks Zone:DNS:Edit. `
          + `Set QM_CF_DNS_TOKEN (a Zone:DNS:Edit token on ${zoneName}) to automate, or add CNAME ${sub} → ${target} (proxied) in ${zoneName}`,
      };
    }
    const dnsEnv = { ...process.env, CF_DNS: dnsToken };
    const zone = getj(`${CF_API}/zones?name=${zoneName}`, "CF_DNS", dnsEnv)?.result?.[0]?.id;
    if (!zone) return { ok: attachedOk, message: `${attachMsg}; DNS: zone ${zoneName} not found with CLOUDFLARE_API_TOKEN` };
    const rec = post(`${CF_API}/zones/${zone}/dns_records`,
      `{"type":"CNAME","name":"${sub}","content":"${target}","proxied":true}`, "CF_DNS", dnsEnv);
    if (rec?.success) return { ok: true, message: `attached + CNAME ${sub} → ${target} created` };
    const dnsMsg = rec?.errors?.[0]?.message || "DNS create failed";
    if (/already exists|identical/i.test(dnsMsg)) return { ok: true, message: "attached; DNS record already present" };
    return { ok: attachedOk, message: `${attachMsg}; DNS: ${dnsMsg}` };
  } catch (e) {
    return { ok: false, message: String(e && e.message ? e.message : e) };
  }
};
