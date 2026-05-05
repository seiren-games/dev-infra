{
  description = "Development infrastructure shared files";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs =
    { nixpkgs, ... }:
    let
      rustCiToolsModule = import ./rust/nix/modules/ci-tools.nix;

      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f {
            pkgs = import nixpkgs { inherit system; };
          }
        );

      evalRustCiTools =
        pkgs:
        nixpkgs.lib.evalModules {
          specialArgs = { inherit pkgs; };
          modules = [
            rustCiToolsModule
          ];
        };
    in
    {
      lib = {
        rustCiToolsModule = rustCiToolsModule;
      };

      packages = forAllSystems (
        { pkgs }:
        {
          rust-ci-tools = (evalRustCiTools pkgs).config.devInfra.rust.ciTools.package;
        }
      );

      devShells = forAllSystems (
        { pkgs }:
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.git
              pkgs.gitleaks
            ];
          };
        }
      );
    };
}
