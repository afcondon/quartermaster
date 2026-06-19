// Quartermaster's hand-written Go twin of cli/src/Quartermaster/CLI/IO.js — the
// file/argv I/O edge. Provides the REAL CLI foreign symbols
// `Quartermaster_CLI_IO_*`, so a backend-go build of the actual
// `Quartermaster.CLI.Main` (the `gnomon-quartermaster` binary,
// scripts/gnomon-quartermaster.sh) reads real compose.yml / registry.json off
// disk and runs the SAME pipeline the node CLI does. APP-SPECIFIC; backend-go
// stays dep-free — only THIS foreign imports yaml.v3 (the build adds a one-line
// go.mod, the go-apply-cli pattern). A near-exact sibling of Bosun's
// bosun_io_foreign.go (minus readJsonUrl, which Quartermaster has no use for).
//
// backend-go ABI: `EffectFn1 a b` → `func(args ...any) any` (runs + returns the
// value); a bare `Effect a` → `func() any` thunk. The returned Json must be the
// interface{} shape argonaut/foreign-object expect: map[string]any / []any /
// float64 (ALL numbers) / string / bool / nil.
package main

import (
	"encoding/json"
	"os"

	"gopkg.in/yaml.v3"
)

// readJsonImpl :: EffectFn1 String Json — read a file and JSON-decode it.
var Quartermaster_CLI_IO_readJsonImpl any = func(args ...any) any {
	path := args[0].(string)
	data, err := os.ReadFile(path)
	if err != nil {
		panic("readJson: " + err.Error())
	}
	var v any
	if err := json.Unmarshal(data, &v); err != nil {
		panic("readJson: " + path + ": " + err.Error())
	}
	return v
}

// readYamlImpl :: EffectFn1 String Json — read a file and YAML-decode it, then
// NORMALISE to the exact runtime shape argonaut/foreign-object expect (the same
// shape encoding/json and js-yaml produce). yaml.v3 into interface{} yields
// map[string]interface{} (or map[any]any) and `int` for whole numbers; we
// stringify keys and widen every int to float64 so the decode path is identical
// to the JSON column.
var Quartermaster_CLI_IO_readYamlImpl any = func(args ...any) any {
	path := args[0].(string)
	data, err := os.ReadFile(path)
	if err != nil {
		panic("readYaml: " + err.Error())
	}
	var v any
	if err := yaml.Unmarshal(data, &v); err != nil {
		panic("readYaml: " + path + ": " + err.Error())
	}
	return ioNormalizeYaml(v)
}

// argv :: Effect (Array String) — the args after the binary name (node's
// process.argv.slice(2) ≡ a native binary's os.Args[1:]).
var Quartermaster_CLI_IO_argv any = func() any {
	out := make([]any, 0, len(os.Args)-1)
	for _, a := range os.Args[1:] {
		out = append(out, a)
	}
	return out
}

func ioNormalizeYaml(v any) any {
	switch x := v.(type) {
	case map[string]any:
		r := make(map[string]any, len(x))
		for k, val := range x {
			r[k] = ioNormalizeYaml(val)
		}
		return r
	case map[any]any:
		r := make(map[string]any, len(x))
		for k, val := range x {
			r[ioYamlKey(k)] = ioNormalizeYaml(val)
		}
		return r
	case []any:
		r := make([]any, len(x))
		for i, val := range x {
			r[i] = ioNormalizeYaml(val)
		}
		return r
	case int:
		return float64(x)
	case int64:
		return float64(x)
	case uint64:
		return float64(x)
	default:
		return v
	}
}

func ioYamlKey(k any) string {
	if s, ok := k.(string); ok {
		return s
	}
	b, _ := json.Marshal(k)
	return string(b)
}
