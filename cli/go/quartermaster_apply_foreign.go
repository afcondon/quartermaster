// Quartermaster's hand-written Go twin of cli/src/Quartermaster/CLI/Apply.js —
// the `quartermaster apply` enactment edge. Provides the REAL CLI foreign symbols
// `Quartermaster_CLI_Apply_*`, so a backend-go build of `Quartermaster.CLI.Main`
// runs the SAME apply pipeline the node CLI does: capture a probe synchronously
// (the no-Aff seam) and stream a long provisioning phase live. APP-SPECIFIC.
//
// captureImpl mirrors quartermaster_probe_foreign.go's shProbeImpl but with a
// 30s budget (an ssh probe round-trip, not a 10s local `command -v`); streamImpl
// is byte-for-byte the same seam as Exec's streamImpl (bash -c, inherited stdio,
// no timeout, exit code out).
//
// backend-go ABI: `EffectFn1 a b` → `func(args ...any) any`; PureScript `Int` is
// Go `int`; a record is a `map[string]any` of Go bool/string/int values.
package main

import (
	"context"
	"os"
	"os/exec"
	"strings"
	"time"
)

// captureImpl :: EffectFn1 String { ok :: Boolean, out :: String } — run a probe
// synchronously, capture trimmed stdout, NEVER throw. ok = exit 0; out = trimmed
// stdout (whatever was captured, empty on failure). 30s ceiling — an ssh probe,
// not a build. Mirrors the JS twin's execSync({stdio:["ignore","pipe","ignore"]})
// and Probe's shProbeImpl (which uses /bin/sh, not bash — a probe is a plain
// `command -v` / `test`, no shell-feature dependency).
var Quartermaster_CLI_Apply_captureImpl any = func(args ...any) any {
	cmd := args[0].(string)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	c := exec.CommandContext(ctx, "/bin/sh", "-c", cmd)
	out, err := c.Output() // stdout only; stderr left at /dev/null
	trimmed := strings.TrimSpace(string(out))
	if err != nil {
		return map[string]any{"ok": false, "out": trimmed}
	}
	return map[string]any{"ok": true, "out": trimmed}
}

// streamImpl :: EffectFn1 String Int — run one apply phase with LIVE inherited
// stdio and NO timeout (Determinate Nix install + cache substitution of GHC/Rust
// closures are minutes-long, megabytes of output). `bash -c` so the ssh heredoc
// applyInvocation renders runs in a real shell. Exit code out: 0 on success, the
// process status on an ExitError, 1 when signal-killed — the JS twin's mapping.
var Quartermaster_CLI_Apply_streamImpl any = func(args ...any) any {
	cmd := args[0].(string)
	c := exec.Command("bash", "-c", cmd)
	c.Stdin = os.Stdin
	c.Stdout = os.Stdout
	c.Stderr = os.Stderr
	err := c.Run()
	if err == nil {
		return 0
	}
	if ee, ok := err.(*exec.ExitError); ok {
		code := ee.ExitCode()
		if code < 0 {
			return 1
		}
		return code
	}
	return 1
}
