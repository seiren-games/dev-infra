{
  description = "Development infrastructure shared files";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs =
    { nixpkgs, ... }:
    let
      rustDevEnvironmentModule = import ./rust/nix/modules/dev-environment.nix;

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

      evalRustDevEnvironment =
        pkgs:
        nixpkgs.lib.evalModules {
          specialArgs = { inherit pkgs; };
          modules = [
            rustDevEnvironmentModule
          ];
        };
    in
    {
      lib = {
        rustDevEnvironmentModule = rustDevEnvironmentModule;
      };

      packages = forAllSystems (
        { pkgs }:
        {
          rust-dev-environment = (evalRustDevEnvironment pkgs).config.devInfra.rust.devEnvironment.package;
        }
      );

      checks = forAllSystems (
        { pkgs }:
        let
          rustDevEnvironment = evalRustDevEnvironment pkgs;
          rustDevEnvironmentPackage = rustDevEnvironment.config.devInfra.rust.devEnvironment.package;
          cargoPackage = rustDevEnvironment.config.devInfra.rust.devEnvironment.cargoPackage;
          cargoCheckManifest = pkgs.writeText "Cargo.toml" ''
            [package]
            name = "cargo-min-publish-age-check"
            version = "0.0.0"
            edition = "2024"

            [lib]
            path = "lib.rs"
          '';
        in
        {
          rust-dev-environment = rustDevEnvironmentPackage;

          rust-min-publish-age =
            pkgs.runCommand "rust-min-publish-age-check"
              {
                nativeBuildInputs = [
                  rustDevEnvironmentPackage
                  pkgs.rustc
                ];
              }
              ''
                cargo --version --verbose > cargo-version
                grep -Fx "commit-hash: ${cargoPackage.commit}" cargo-version

                cargo -Z help > unstable-features
                grep -F -- "-Z min-publish-age" unstable-features

                cd ${./rust}
                cargo -Zunstable-options config get unstable.min-publish-age > "$TMPDIR/min-publish-age"
                cargo -Zunstable-options config get resolver.incompatible-publish-age > "$TMPDIR/incompatible-publish-age"
                cargo -Zunstable-options config get registry.global-min-publish-age > "$TMPDIR/global-min-publish-age"

                grep -Fx 'unstable.min-publish-age = true' "$TMPDIR/min-publish-age"
                grep -Fx 'resolver.incompatible-publish-age = "deny"' "$TMPDIR/incompatible-publish-age"
                grep -Fx 'registry.global-min-publish-age = "7 days"' "$TMPDIR/global-min-publish-age"

                if cargo -Zunstable-options config get registry.min-publish-age > /dev/null 2>&1; then
                  echo "registry.min-publish-age must not override the global policy" >&2
                  exit 1
                fi

                if cargo -Zunstable-options config get registries 2> /dev/null \
                  | grep -F ".min-publish-age"; then
                  echo "registries.<name>.min-publish-age must not override the global policy" >&2
                  exit 1
                fi

                mkdir -p "$TMPDIR/project/.cargo" "$TMPDIR/project/lockfile"
                cp ${cargoCheckManifest} "$TMPDIR/project/Cargo.toml"
                cp ${./rust/.cargo/config.toml} "$TMPDIR/project/.cargo/config.toml"
                touch "$TMPDIR/project/lib.rs"
                cd "$TMPDIR/project"
                CARGO_RESOLVER_LOCKFILE_PATH="$TMPDIR/project/lockfile/Cargo.lock" \
                  cargo generate-lockfile
                test -f "$TMPDIR/project/lockfile/Cargo.lock"
                test ! -e "$TMPDIR/project/Cargo.lock"

                touch "$out"
              '';
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
