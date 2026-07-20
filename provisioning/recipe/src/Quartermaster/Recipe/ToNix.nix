{ # Resolve a nixpkgs access path against the package collection:
  # attrByPath ["haskell" "compiler" "ghc98"] pkgs == pkgs.haskell.compiler.ghc98
  attrByPath  = path: set: builtins.foldl' (s: k: s.${k}) set path;

  # The two builder operations, taken from the collection itself.
  mkShell     = pkgs: args: pkgs.mkShell args;
  buildEnv    = pkgs: args: pkgs.buildEnv args;

  # Attrset / list plumbing the fold needs, kept Prim-side as primitives.
  listToAttrs = builtins.listToAttrs;
  mapArray    = f: builtins.map f;
  concatArray = a: b: a ++ b;
  filterArray = f: builtins.filter f;
  head        = xs: builtins.head xs;
  stringEq    = a: b: a == b;
}
