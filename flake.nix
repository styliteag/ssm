{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    systems.url = "github:nix-systems/default";
    rust-flake.url = "github:juspay/rust-flake";
    rust-flake.inputs.nixpkgs.follows = "nixpkgs";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;

      imports = [
        inputs.rust-flake.flakeModules.default
        inputs.rust-flake.flakeModules.nixpkgs
        inputs.treefmt-nix.flakeModule
      ];

      perSystem =

        {
          config,
          self',
          pkgs,
          lib,
          ...
        }:
        {
          treefmt.config = {
            projectRootFile = "flake.nix";
            programs = {
              nixpkgs-fmt.enable = true;
              rustfmt.enable = true;
            };
          };

          rust-project.crates."ssm".crane.args = {
            buildInputs = with pkgs; [
              postgresql
            ];
          };

          devShells.default = pkgs.mkShell {
            name = "ssm_devshell";
            inputsFrom = [
              self'.devShells.rust
              config.treefmt.build.devShell
            ];
            packages = [
              pkgs.diesel-cli
              pkgs.sqlite
              pkgs.docker-buildx
            ];
          };
        };
    };
}
