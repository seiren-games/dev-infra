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
            set -e
            for arg in "$@"; do
              if [ "$arg" = cooldown ]; then
                [ "$COOLDOWN_MINUTES" = 10080 ]
                [ "$COOLDOWN_ENFORCEMENT" = strict ]
                [ "$COOLDOWN_LOCKFILE_BASELINE" = ignore ]
                [ "$(command -v cargo-cooldown)" != "$FAKE_CARGO_DIR/cargo-cooldown" ]
                break
              fi
            done
            printf '%s\n' "$*" >> "$CARGO_CALL_LOG"
            EOF
            chmod +x "$fake_cargo/cargo"

            cat > "$fake_cargo/cargo-cooldown" <<'EOF'
            #!${pkgs.runtimeShell}
            printf 'unpinned cargo-cooldown must not be selected\n' >&2
            exit 1
            EOF
            chmod +x "$fake_cargo/cargo-cooldown"

            assert_cargo_invocation() {
              local expected="$1"
              shift
              : > "$CARGO_CALL_LOG"
              PATH="${rustDevEnvironment}/bin:$fake_cargo:$PATH" cargo "$@"
              diff -u <(printf '%s\n' "$expected") "$CARGO_CALL_LOG"
            }

            assert_calls() {
              local command="$1"
              local expected="$2"
              shift 2

              assert_cargo_invocation "$expected" "$command" "$@"
            }

            export CARGO_CALL_LOG="$TMPDIR/cargo-calls"
            export FAKE_CARGO_DIR="$fake_cargo"

            assert_calls add $'cooldown add serde\ncooldown metadata --locked --format-version=1 --all-features' serde
            assert_calls add \
              $'cooldown add serde --manifest-path crates/app/Cargo.toml\ncooldown metadata --locked --format-version=1 --all-features --manifest-path crates/app/Cargo.toml' \
              serde \
              --manifest-path crates/app/Cargo.toml
            assert_calls add \
              $'cooldown add -p member serde\ncooldown metadata --locked --format-version=1 --all-features' \
              -p member serde
            assert_calls add \
              $'cooldown add --workspace --exclude old-app serde --features derive,alloc --all-features --no-default-features\ncooldown metadata --locked --format-version=1 --all-features' \
              --workspace --exclude old-app serde --features derive,alloc --all-features --no-default-features
            assert_calls add \
              $'cooldown add serde --features derive\ncooldown metadata --locked --format-version=1 --all-features' \
              serde --features derive
            assert_calls add \
              $'cooldown add --path ../dep\ncooldown metadata --locked --format-version=1 --all-features' \
              --path ../dep
            assert_calls add \
              $'cooldown add serde --path=../dep\ncooldown metadata --locked --format-version=1 --all-features' \
              serde --path=../dep
            assert_calls fetch $'cooldown fetch\ncooldown metadata --locked --format-version=1 --all-features'
            assert_calls fetch $'cooldown fetch --offline\ncooldown metadata --locked --format-version=1 --all-features --offline' --offline
            assert_calls add $'cooldown add serde --frozen\ncooldown metadata --locked --format-version=1 --all-features --frozen' serde --frozen
            assert_calls add "add serde --dry-run" serde --dry-run
            assert_cargo_invocation "--offline add serde --dry-run" --offline add serde --dry-run
            assert_calls update "update --dry-run" --dry-run
            assert_calls update "cooldown update"
            assert_cargo_invocation "cooldown update --offline" --offline update
            assert_cargo_invocation \
              $'cooldown fetch --offline\ncooldown metadata --offline --locked --format-version=1 --all-features' \
              --offline \
              fetch
            assert_cargo_invocation \
              $'cooldown upgrade --offline --locked\ncooldown metadata --offline --locked --format-version=1 --all-features' \
              --offline \
              upgrade \
              --locked
            assert_cargo_invocation \
              $'cooldown add --config net.offline=true serde\ncooldown metadata --config net.offline=true --locked --format-version=1 --all-features' \
              --config net.offline=true \
              add \
              serde
            assert_calls update "update --help" --help
            assert_calls add "add --help" --help
            assert_calls build "build --locked"
            assert_calls clippy "clippy --locked"
            assert_calls info "info serde" serde
            assert_cargo_invocation "--offline build --locked" --offline build
            assert_calls audit "audit --deny warnings" --deny warnings
            assert_cargo_invocation "--offline audit" --offline audit
            assert_cargo_invocation "--config net.offline=true deny" --config net.offline=true deny
            assert_calls build "build --help" --help
            assert_calls build "build --locked --dry-run" --dry-run
            assert_calls run "run --locked -- --help" -- --help
            assert_calls test "test --locked -- --help" -- --help

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
