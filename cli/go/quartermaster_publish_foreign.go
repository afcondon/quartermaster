// Quartermaster's hand-written Go twin of cli/src/Quartermaster/CLI/Publish.js —
// the `quartermaster publish` edge (ship each static-CDN site via the
// cloudflare-pages-wrangler channel). Provides the REAL CLI foreign symbols
// `Quartermaster_CLI_Publish_*`, so a backend-go build of `Quartermaster.CLI.Main`
// runs the SAME publish pipeline the node CLI does. APP-SPECIFIC.
//
//   runStreamImpl        — like quartermaster_build_foreign.go: inherited stdio
//                          (wrangler upload progress streams live), no timeout,
//                          { ok = exit 0 }. execSync uses /bin/sh, so we do too.
//   ensureCustomDomainImpl — a faithful port of the JS: attach the Pages custom
//                          domain (wrangler OAuth token) + create the zone CNAME
//                          (a scoped QM_CF_DNS_TOKEN). Non-fatal throughout — the
//                          deploy is the real verdict. curl via /bin/sh with the
//                          token in the env (never the command string), exactly
//                          as the JS twin does; JS throw/catch → Go panic/recover.
//
// backend-go ABI: `EffectFn1 a b` / `EffectFn2 a b c` → `func(args ...any) any`
// (args[0], args[1] are the arguments); a record is a `map[string]any` of Go
// bool/string values.
package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

const publishCfApi = "https://api.cloudflare.com/client/v4"

// runStreamImpl :: EffectFn1 String { ok :: Boolean } — run a publish command
// with INHERITED stdio (wrangler progress streams straight to the terminal) and
// no timeout. ok = exit 0. Mirrors the JS twin's execSync({stdio:"inherit"}).
var Quartermaster_CLI_Publish_runStreamImpl any = func(args ...any) any {
	cmd := args[0].(string)
	c := exec.Command("/bin/sh", "-c", cmd)
	c.Stdin = os.Stdin
	c.Stdout = os.Stdout
	c.Stderr = os.Stderr
	err := c.Run()
	return map[string]any{"ok": err == nil}
}

// ensureCustomDomainImpl :: EffectFn2 String String { ok :: Boolean, message :: String }
var Quartermaster_CLI_Publish_ensureCustomDomainImpl any = func(args ...any) (result any) {
	project := args[0].(string)
	domain := args[1].(string)
	// JS wraps the whole body in try/catch → { ok:false, message }. panic/recover
	// gives the same non-fatal edge (a curl/JSON failure never aborts the deploy).
	defer func() {
		if r := recover(); r != nil {
			result = map[string]any{"ok": false, "message": publishErrString(r)}
		}
	}()

	// wrangler's stored OAuth token (the ambient auth the deploy just used).
	home, _ := os.UserHomeDir()
	cfg, err := os.ReadFile(filepath.Join(home, ".wrangler", "config", "default.toml"))
	if err != nil {
		return map[string]any{"ok": false, "message": "no wrangler oauth_token found — run `wrangler login`"}
	}
	m := regexp.MustCompile(`oauth_token\s*=\s*"([^"]+)"`).FindStringSubmatch(string(cfg))
	if m == nil {
		return map[string]any{"ok": false, "message": "no wrangler oauth_token found — run `wrangler login`"}
	}
	oauthEnv := append(os.Environ(), "CF_TOKEN="+m[1])

	// resolve account id
	acct, _ := publishFirstResultID(publishGetJ(publishCfApi+"/accounts", "CF_TOKEN", oauthEnv))
	if acct == "" {
		return map[string]any{"ok": false, "message": "could not resolve CF account id"}
	}

	// 1. attach the custom domain to the Pages project (idempotent)
	attach := publishPost(
		publishCfApi+"/accounts/"+acct+"/pages/projects/"+project+"/domains",
		`{"name":"`+domain+`"}`, "CF_TOKEN", oauthEnv)
	attachSuccess := publishBool(attach, "success")
	attachMsg := "attach failed"
	if attachSuccess {
		attachMsg = "attached"
	} else if em := publishFirstErrorMessage(attach); em != "" {
		attachMsg = em
	}
	attachedOk := attachSuccess || regexp.MustCompile(`(?i)already|exists`).MatchString(attachMsg)

	// 2. the zone CNAME (<sub> -> <project>.pages.dev, proxied) — Zone:DNS:Edit
	labels := strings.Split(domain, ".")
	zoneName := strings.Join(labels[max0(len(labels)-2):], ".")
	sub := "@"
	if len(labels) > 2 {
		sub = strings.Join(labels[:len(labels)-2], ".")
	}
	target := project + ".pages.dev"

	dnsToken := os.Getenv("QM_CF_DNS_TOKEN")
	if dnsToken == "" {
		return map[string]any{
			"ok": attachedOk,
			"message": attachMsg + " (pending) — DNS not created: the wrangler OAuth token lacks Zone:DNS:Edit. " +
				"Set QM_CF_DNS_TOKEN (a Zone:DNS:Edit token on " + zoneName + ") to automate, or add CNAME " +
				sub + " → " + target + " (proxied) in " + zoneName,
		}
	}
	dnsEnv := append(os.Environ(), "CF_DNS="+dnsToken)
	zone, _ := publishFirstResultID(publishGetJ(publishCfApi+"/zones?name="+zoneName, "CF_DNS", dnsEnv))
	if zone == "" {
		return map[string]any{"ok": attachedOk, "message": attachMsg + "; DNS: zone " + zoneName + " not found with CLOUDFLARE_API_TOKEN"}
	}
	rec := publishPost(publishCfApi+"/zones/"+zone+"/dns_records",
		`{"type":"CNAME","name":"`+sub+`","content":"`+target+`","proxied":true}`, "CF_DNS", dnsEnv)
	if publishBool(rec, "success") {
		return map[string]any{"ok": true, "message": "attached + CNAME " + sub + " → " + target + " created"}
	}
	dnsMsg := publishFirstErrorMessage(rec)
	if dnsMsg == "" {
		dnsMsg = "DNS create failed"
	}
	if regexp.MustCompile(`(?i)already exists|identical`).MatchString(dnsMsg) {
		return map[string]any{"ok": true, "message": "attached; DNS record already present"}
	}
	return map[string]any{"ok": attachedOk, "message": attachMsg + "; DNS: " + dnsMsg}
}

// publishPost / publishGetJ mirror the JS `post` / `getj`: curl via /bin/sh with
// the bearer token expanded from the env ($<name>), stdout JSON-parsed. A parse
// failure panics — caught by ensureCustomDomainImpl's recover, as JSON.parse's
// throw is caught by the JS try/catch.
func publishPost(url, body, tokenEnvName string, env []string) any {
	cmd := `curl -s -X POST -H "Authorization: Bearer $` + tokenEnvName +
		`" -H "Content-Type: application/json" ` + url + ` --data '` + body + `'`
	return publishCurlJSON(cmd, env)
}

func publishGetJ(url, tokenEnvName string, env []string) any {
	cmd := `curl -s -H "Authorization: Bearer $` + tokenEnvName + `" ` + url
	return publishCurlJSON(cmd, env)
}

func publishCurlJSON(cmd string, env []string) any {
	c := exec.Command("/bin/sh", "-c", cmd)
	c.Env = env
	out, err := c.Output()
	if err != nil {
		panic(err)
	}
	var v any
	if err := json.Unmarshal(out, &v); err != nil {
		panic(err)
	}
	return v
}

// publishFirstResultID: v?.result?.[0]?.id (empty string when any hop is absent).
func publishFirstResultID(v any) (string, bool) {
	res := publishField(v, "result")
	arr, ok := res.([]any)
	if !ok || len(arr) == 0 {
		return "", false
	}
	id, ok := publishField(arr[0], "id").(string)
	return id, ok
}

// publishFirstErrorMessage: v?.errors?.[0]?.message ("" when absent).
func publishFirstErrorMessage(v any) string {
	errs := publishField(v, "errors")
	arr, ok := errs.([]any)
	if !ok || len(arr) == 0 {
		return ""
	}
	msg, _ := publishField(arr[0], "message").(string)
	return msg
}

func publishField(v any, key string) any {
	if m, ok := v.(map[string]any); ok {
		return m[key]
	}
	return nil
}

func publishBool(v any, key string) bool {
	b, _ := publishField(v, key).(bool)
	return b
}

func publishErrString(r any) string {
	if err, ok := r.(error); ok {
		return err.Error()
	}
	if s, ok := r.(string); ok {
		return s
	}
	return "publish: custom-domain error"
}

func max0(n int) int {
	if n < 0 {
		return 0
	}
	return n
}
