# Derivation-hash equivalence: the PureScript-authored recipe vs the
# hand-written flake.nix. If every derivation hash matches, the recipe
# provably produces the identical provisioning. Paths come from the
# environment (set by bin/verify.sh) so this file stays path-agnostic.
let
  qmPath = builtins.getEnv "QM_PATH";
  recipeOut = builtins.getEnv "RECIPE_OUT";

  qm = builtins.getFlake ("git+file://" + qmPath);
  sys = builtins.currentSystem;
  pkgs = import qm.inputs.nixpkgs {
    system = sys;
    overlays = [ qm.inputs.purescript-overlay.overlays.default ];
  };

  recipe = (import recipeOut).flake pkgs;

  fShells = qm.devShells.${sys};
  rShells = recipe.devShells;
  fPkgs = qm.packages.${sys};
  rPkgs = recipe.packages;

  shellNames = [ "purescript" "rust" "erlang" "node" "go" "haskell" "purerl" "default" ];
  pkgNames = [
    "purs" "spago" "purs-tidy" "esbuild" "erlang" "rebar3"
    "purescript-language-server" "node" "go" "python" "rustc" "cargo"
    "rust-analyzer" "ghc" "cabal" "stack" "ffmpeg" "tools"
  ];

  check = kind: n: f: r: { ok = f.drvPath == r.drvPath; inherit kind n; fp = f.drvPath; rp = r.drvPath; };
  results =
    (map (n: check "devShell" n fShells.${n} rShells.${n}) shellNames)
    ++ (map (n: check "package " n fPkgs.${n} rPkgs.${n}) pkgNames);

  fmt = c:
    if c.ok
    then "  OK   ${c.kind} ${c.n}"
    else "  DIFF ${c.kind} ${c.n}\n      flake:  ${c.fp}\n      recipe: ${c.rp}";

  nDiff = builtins.length (builtins.filter (c: !c.ok) results);
in
builtins.concatStringsSep "\n" (map fmt results)
+ "\n\n"
+ (if nDiff == 0
   then "ALL EQUIVALENT — recipe produces byte-identical derivations to flake.nix"
   else toString nDiff + " DIFFERENCE(S)")
