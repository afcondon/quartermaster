{
  # The substrate's pinned toolchain manifest — Quartermaster's artifact
  # for the Nix-base-layer mandate (kb/plans/nix-base-layer.md,
  # 2026-07-18). One flake + one lock = the definition of "provisioned"
  # on every machine the substrate reaches; the replication test is that
  # two machines realize IDENTICAL store paths from it.
  #
  # Deliberately toolchains-only: projects keep building with spago /
  # cargo / rebar3 exactly as before (incremental inner loops stay
  # outside Nix); this flake just supplies definitive tool binaries.
  description = "Quartermaster: the substrate's pinned toolchains";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    purescript-overlay = {
      url = "github:thomashoneyman/purescript-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, purescript-overlay }:
    let
      # no machine-specific assumptions: every system the fleet could
      # plausibly reach, Macs merely first among equals
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system:
        f (import nixpkgs {
          inherit system;
          overlays = [ purescript-overlay.overlays.default ];
        }));
    in
    {
      devShells = forAllSystems (pkgs: rec {
        # the lingua franca shell — purs pinned to the version the
        # registry package sets in use assume (0.15.15, matching the
        # pre-Nix machines byte-for-byte in behaviour); node included
        # because the JS backend's output runs on it (spago test)
        purescript = pkgs.mkShell {
          packages = [
            pkgs.purs-bin.purs-0_15_15
            pkgs.spago-unstable
            pkgs.purs-tidy
            pkgs.nodejs_22
            pkgs.git # spago shells out to it; not assumed on fleet hosts
          ];
        };

        rust = pkgs.mkShell {
          packages = [ pkgs.rustc pkgs.cargo ];
        };

        erlang = pkgs.mkShell {
          packages = [ pkgs.erlang_28 pkgs.rebar3 ];
        };

        node = pkgs.mkShell {
          packages = [ pkgs.nodejs_22 ];
        };

        # purerl-tidal needs BOTH the BEAM toolchain (erlang backend
        # runtime + rebar3) AND the PureScript toolchain (compile +
        # tidy) — it's a PureScript source tree that targets Erlang.
        purerl = pkgs.mkShell {
          packages = [
            pkgs.erlang_28
            pkgs.rebar3
            pkgs.purs-bin.purs-0_15_15
            pkgs.spago-unstable
            pkgs.purs-tidy
            pkgs.nodejs_22
          ];
        };

        default = purescript;
      });

      # Individual tool binaries + an aggregate CLI-tools bundle, so the
      # fleet can `nix build .#tools` for a single provisioned profile
      # rather than depending on `nix develop` shells alone.
      packages = forAllSystems (pkgs: {
        purs = pkgs.purs-bin.purs-0_15_15;
        spago = pkgs.spago-unstable;
        purs-tidy = pkgs.purs-tidy;
        esbuild = pkgs.esbuild;
        erlang = pkgs.erlang_28;
        rebar3 = pkgs.rebar3;
        # provided at nixpkgs top level (not the overlay); pins the LSP
        # that cclsp drives against the same purs as the shells.
        purescript-language-server = pkgs.purescript-language-server;

        # the everyday CLI kit — one buildEnv so `nix profile install
        # .#tools` (review-gated, not done here) yields one entry.
        # ffmpeg deliberately excluded: huge closure, decided later.
        tools = pkgs.buildEnv {
          name = "afc-cli-tools";
          paths = [
            pkgs.gh
            pkgs.fd
            pkgs.ripgrep
            pkgs.cloc
            pkgs.duckdb
            pkgs.cmake
            pkgs.jq
            pkgs.tree
            pkgs.tmux
            pkgs.pandoc
            pkgs.graphviz
            pkgs.exiftool
            pkgs.httpie
            pkgs.direnv
            pkgs.git-lfs
          ];
        };
      });
    };
}
