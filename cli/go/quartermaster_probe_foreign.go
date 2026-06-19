// Quartermaster's hand-written Go twin of cli/src/Quartermaster/CLI/Probe.js —
// the synchronous host-capability PROBE edge. Provides the REAL CLI foreign
// symbol `Quartermaster_CLI_Probe_shProbeImpl`, so a backend-go build of
// `Quartermaster.CLI.Main` runs the SAME `command -v` / `test -d` / ssh-wrapped
// checks the node CLI does. APP-SPECIFIC.
//
// Synchronous on purpose — the no-Aff seam. Mirrors its JS twin's contract
// exactly: run `/bin/sh -c <cmd>`, never throw; { ok = exit 0, out = trimmed
// stdout } (empty out on failure). 10s budget, matching execSync's timeout.
//
// backend-go ABI: `EffectFn1 String r` → `func(args ...any) any`; the returned
// record `{ ok :: Boolean, out :: String }` is a `map[string]any` with Go `bool`
// / `string` values (the shape PureScript record accessors read at runtime).
package main

import (
	"context"
	"os/exec"
	"strings"
	"time"
)

var Quartermaster_CLI_Probe_shProbeImpl any = func(args ...any) any {
	cmd := args[0].(string)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	// /bin/sh -c <cmd>, like node's execSync. stdin ignored, stderr discarded,
	// stdout captured — exactly the JS twin's stdio: ["ignore","pipe","ignore"].
	c := exec.CommandContext(ctx, "/bin/sh", "-c", cmd)
	out, err := c.Output() // captures stdout only; stderr left at /dev/null
	trimmed := strings.TrimSpace(string(out))
	if err != nil {
		return map[string]any{"ok": false, "out": trimmed}
	}
	return map[string]any{"ok": true, "out": trimmed}
}
