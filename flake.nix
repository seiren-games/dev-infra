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
          rust-dev-environment =
            (evalRustDevEnvironment pkgs).config.devInfra.rust.devEnvironment.package;
        }
      );

      checks = forAllSystems (
        { pkgs }:
        let
          rustDevEnvironment =
            (evalRustDevEnvironment pkgs).config.devInfra.rust.devEnvironment.package;
        in
        {
          rust-dev-environment = rustDevEnvironment;

          rust-dev-environment-wrapper-policy = pkgs.runCommand "dev-infra-rust-wrapper-policy-check" { } ''
            fake_cargo="$TMPDIR/fake-cargo/bin"
            mkdir -p "$fake_cargo"

            cat > "$fake_cargo/cargo" <<'EOF'
            #!${pkgs.runtimeShell}
            printf '%s\n' "$*" >> "$CARGO_CALL_LOG"
            EOF
            chmod +x "$fake_cargo/cargo"

            assert_calls() {
              local command="$1"
              local expected="$2"
              shift 2

              : > "$CARGO_CALL_LOG"
              PATH="${rustDevEnvironment}/bin:$fake_cargo:$PATH" cargo "$command" "$@"
              diff -u <(printf '%s\n' "$expected") "$CARGO_CALL_LOG"
            }

            export CARGO_CALL_LOG="$TMPDIR/cargo-calls"

            assert_calls add $'cooldown add serde\ncooldown metadata --locked --format-version=1' serde
            assert_calls add \
              $'cooldown add serde --manifest-path crates/app/Cargo.toml\ncooldown --manifest-path crates/app/Cargo.toml metadata --locked --format-version=1' \
              serde \
              --manifest-path crates/app/Cargo.toml
            assert_calls fetch $'cooldown fetch\ncooldown metadata --locked --format-version=1'
            assert_calls update "cooldown update"
            assert_calls update "update --help" --help
            assert_calls add "add --help" --help
            assert_calls build "--locked build"
            assert_calls build "build --help" --help

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
