// Quartermaster's hand-written Go twin of cli/src/Quartermaster/CLI/Exec.js —
// the `quartermaster exec` effectful edge. Provides the REAL CLI foreign symbols
// `Quartermaster_CLI_Exec_*`, so a backend-go build of `Quartermaster.CLI.Main`
// runs the SAME exec pipeline the node CLI does: read `.envrc` to auto-detect a
// flake dev-shell, run the rendered script live with inherited stdio, and
// propagate the wrapped command's exit code. APP-SPECIFIC. The nearest sibling
// is quartermaster_build_foreign.go (also a long, chatty, inherited-stdio, no-
// timeout exec) — Exec adds the `.envrc` reader and exit-code propagation.
//
// backend-go ABI: `EffectFn1 a b` → `func(args ...any) any` (runs + returns the
// value); PureScript `Int` is Go `int`; a record `{ … }` is a `map[string]any`
// whose values are the Go bool/string/int the record accessors read at runtime.
package main

import (
	"os"
	"os/exec"
)

// readFileImpl :: EffectFn1 String { found :: Boolean, contents :: String } —
// read a file at the edge, NEVER throwing. found = false (contents "") when the
// file is absent, so a repo without an `.envrc` simply resolves to "no flake".
// Mirrors the JS twin's readFileSync-in-a-try/catch.
var Quartermaster_CLI_Exec_readFileImpl any = func(args ...any) any {
	path := args[0].(string)
	data, err := os.ReadFile(path)
	if err != nil {
		return map[string]any{"found": false, "contents": ""}
	}
	return map[string]any{"found": true, "contents": string(data)}
}

// streamImpl :: EffectFn1 String Int — run the rendered exec script with LIVE
// inherited stdio and NO timeout (a wrapped `spago build` is minutes-long and
// megabytes of output; a buffered/timed exec would truncate it). `bash -c` so
// the source-daemon preamble + `exec …` runs in a real shell — NOT `/bin/sh`,
// matching the JS twin (and Apply's streamImpl). Returns the wrapped command's
// exit code: 0 on success, the process' exit status on an ExitError, and 1 when
// it was killed by a signal (ExitCode() == -1) — the same mapping as the JS
// twin's `r.status` / `r.signal ? 1 : 0`.
var Quartermaster_CLI_Exec_streamImpl any = func(args ...any) any {
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
		code := ee.ExitCode() // -1 when terminated by a signal (no exit status)
		if code < 0 {
			return 1
		}
		return code
	}
	// Failed to start (e.g. bash not found) — treat as a nonzero failure.
	return 1
}

// setExitCode :: EffectFn1 Int Unit — make the wrapped command's status become
// quartermaster's. The generated `main()` just runs the effect and returns
// (exit 0), so — unlike node's deferred `process.exitCode = code` — the Go twin
// propagates by exiting NOW. Safe: streamImpl already ran the child with the
// real stdio fds inherited, so there is nothing buffered in this process to
// flush. This is the last effect in runExecLive, so os.Exit ends the program.
var Quartermaster_CLI_Exec_setExitCode any = func(args ...any) any {
	os.Exit(args[0].(int))
	return nil // unreachable; Go requires a return for the func(...any) any type
}
