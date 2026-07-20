// JS-backend FFI stub for the Nix-only ToNix interpreter.
//
// ToNix is compiled to Nix by Nyx (its real FFI is the co-located ToNix.nix);
// it is NEVER executed under the JS backend. This file exists only so that
// `spago build` (which compiles the whole src/ tree, ToNix included) can
// satisfy purs's FFI-export check for the docs/JS path. Every export throws:
// if one is ever called under JS it means something is wired wrong.
//
// Exactly the nine foreign values are exported — no more, no less — so purs
// does not flag unused/missing FFI implementations.
const nixOnly = () => {
  throw new Error("ToNix is a Nix-only interpreter; compile it via Nyx (bin/verify.sh), not the JS backend");
};

export const mkShell = nixOnly;
export const buildEnv = nixOnly;
export const listToAttrs = nixOnly;
export const mapArray = nixOnly;
export const attrByPath = nixOnly;
export const concatArray = nixOnly;
export const filterArray = nixOnly;
export const head = nixOnly;
export const stringEq = nixOnly;
