// Quartermaster's Go twin of cli/src/Quartermaster/CLI/Build.js — the build/ship
// exec edge. Provides the REAL CLI foreign symbol
// `Quartermaster_CLI_Build_runStreamImpl`, so the native gnomon-quartermaster
// binary runs `docker build`/`docker push` (ssh-wrapped to the build host) the
// same way the node CLI does. APP-SPECIFIC.
//
// Unlike the probe twin (short, captured, 10s), a build is long and chatty, so
// this INHERITS stdio — docker progress streams straight to the terminal — and
// has no timeout. Mirrors node's execSync({stdio:"inherit"}): ok = exit 0.
package main

import (
	"os"
	"os/exec"
)

var Quartermaster_CLI_Build_runStreamImpl any = func(args ...any) any {
	cmd := args[0].(string)
	c := exec.Command("/bin/sh", "-c", cmd)
	c.Stdin = os.Stdin
	c.Stdout = os.Stdout
	c.Stderr = os.Stderr
	err := c.Run()
	return map[string]any{"ok": err == nil}
}
