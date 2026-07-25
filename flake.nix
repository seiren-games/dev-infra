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

      checks = forAllSystems (
        { pkgs }:
        let
          rustDevEnvironment = evalRustDevEnvironment pkgs;
          rustDevEnvironmentPackage = rustDevEnvironment.config.devInfra.rust.devEnvironment.package;
          rustDevEnvironmentShell = rustDevEnvironment.config.devInfra.rust.devEnvironment.devShell;
          cargoPackage = rustDevEnvironment.config.devInfra.rust.devEnvironment.cargoPackage;
          cargoCheckManifest = pkgs.writeText "Cargo.toml" ''
            [package]
            name = "cargo-min-publish-age-check"
            version = "0.0.0"
            edition = "2024"

            [lib]
            path = "lib.rs"

            [dependencies]
            bar = "1"
          '';
          cargoCheckRegistryConfig = pkgs.writeText "config.json" ''
            {"dl":"file:///nonexistent"}
          '';
          # With the resolver clock below, 1.0.0 is 14 days old and 1.1.0 is 2 days old.
          cargoCheckRegistryEntries = pkgs.writeText "bar" ''
            {"name":"bar","vers":"1.0.0","deps":[],"cksum":"0000000000000000000000000000000000000000000000000000000000000000","features":{},"yanked":false,"pubtime":"2006-07-25T00:00:00Z"}
            {"name":"bar","vers":"1.1.0","deps":[],"cksum":"1111111111111111111111111111111111111111111111111111111111111111","features":{},"yanked":false,"pubtime":"2006-08-06T00:00:00Z"}
          '';
          rustAnalyzerCargoHomeRelative = ".vscode/rust-analyzer-cargo-home";
          rustAnalyzerCargoWrapper = ./rust + "/${rustAnalyzerCargoHomeRelative}/bin/cargo";
          rustAnalyzerCargoHomeSetting = "\${workspaceFolder}/${rustAnalyzerCargoHomeRelative}";
          rustAnalyzerCargoSetting = "${rustAnalyzerCargoHomeSetting}/bin/cargo";
          rustAnalyzerPathSetting = "${rustAnalyzerCargoHomeSetting}/bin:\${env:PATH}";
          rustAnalyzerRunnableSetting = "./${rustAnalyzerCargoHomeRelative}/bin/cargo";
          rustAnalyzerDirenvStub = pkgs.writeShellScriptBin "direnv" ''
            set -euo pipefail

            test "$#" -eq 5
            test "$1" = "exec"
            test "$2" = "$EXPECTED_PROJECT_ROOT"
            test "$3" = "cargo"
            test "$4" = "metadata"
            test "$5" = "--argument with spaces"
            test -z "''${CARGO+x}"
            test -z "''${CARGO_HOME+x}"
            test -z "''${RUSTUP_TOOLCHAIN+x}"

            if test "''${WRAPPER_DIRENV_FAIL:-}" = "1"; then
              exit 42
            fi

            touch "$WRAPPER_DIRENV_RESULT"
          '';
        in
        {
          rust-dev-environment = rustDevEnvironmentShell;

          rust-envrc = pkgs.runCommand "rust-envrc-check" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
            shellcheck ${./rust/.envrc}
            touch "$out"
          '';

          rust-vscode-cargo =
            pkgs.runCommand "rust-vscode-cargo-check"
              {
                nativeBuildInputs = [
                  pkgs.jq
                  pkgs.shellcheck
                  rustAnalyzerDirenvStub
                ];
              }
              ''
                shellcheck ${rustAnalyzerCargoWrapper}
                test -x ${rustAnalyzerCargoWrapper}

                tail -n +2 ${./rust/.vscode/settings.json} > "$TMPDIR/settings.json"
                jq -e \
                  --arg cargoHome '${rustAnalyzerCargoHomeSetting}' \
                  --arg cargo '${rustAnalyzerCargoSetting}' \
                  --arg path '${rustAnalyzerPathSetting}' \
                  --arg runnable '${rustAnalyzerRunnableSetting}' \
                  '
                    .["task.autoDetect"] == "off"
                    and .["rust-analyzer.server.extraEnv"].CARGO_HOME == $cargoHome
                    and .["rust-analyzer.server.extraEnv"].CARGO == $cargo
                    and .["rust-analyzer.server.extraEnv"].PATH == $path
                    and .["rust-analyzer.runnables.command"] == $runnable
                  ' \
                  "$TMPDIR/settings.json"

                consumer="$TMPDIR/consumer with spaces"
                wrapper="$consumer/${rustAnalyzerCargoHomeRelative}/bin/cargo"
                mkdir -p "$(dirname "$wrapper")"
                cp ${rustAnalyzerCargoWrapper} "$wrapper"
                chmod +x "$wrapper"
                patchShebangs "$wrapper"

                if CARGO=host-cargo \
                  CARGO_HOME=host-cargo-home \
                  RUSTUP_TOOLCHAIN=host-toolchain \
                  EXPECTED_PROJECT_ROOT="$consumer" \
                  WRAPPER_DIRENV_RESULT="$TMPDIR/direnv-invoked" \
                  "$wrapper" metadata "--argument with spaces"; then
                  echo "the Cargo wrapper must reject a missing .envrc" >&2
                  exit 1
                else
                  status="$?"
                fi
                test "$status" -eq 1
                test ! -e "$TMPDIR/direnv-invoked"

                touch "$consumer/.envrc"
                CARGO=host-cargo \
                  CARGO_HOME=host-cargo-home \
                  RUSTUP_TOOLCHAIN=host-toolchain \
                  EXPECTED_PROJECT_ROOT="$consumer" \
                  WRAPPER_DIRENV_RESULT="$TMPDIR/direnv-invoked" \
                  "$wrapper" metadata "--argument with spaces"
                test -f "$TMPDIR/direnv-invoked"

                if CARGO=host-cargo \
                  CARGO_HOME=host-cargo-home \
                  RUSTUP_TOOLCHAIN=host-toolchain \
                  EXPECTED_PROJECT_ROOT="$consumer" \
                  WRAPPER_DIRENV_RESULT="$TMPDIR/direnv-invoked" \
                  WRAPPER_DIRENV_FAIL=1 \
                  "$wrapper" metadata "--argument with spaces"; then
                  echo "the Cargo wrapper must propagate direnv failures" >&2
                  exit 1
                else
                  status="$?"
                fi
                test "$status" -eq 42

                touch "$out"
              '';

          rust-min-publish-age =
            assert rustDevEnvironmentShell.DEV_INFRA_RUST_NIGHTLY_CARGO_COMMIT == cargoPackage.commit;
            pkgs.runCommand "rust-min-publish-age-check"
              {
                nativeBuildInputs = [
                  rustDevEnvironmentPackage
                  pkgs.git
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

                mkdir -p \
                  "$TMPDIR/cargo-home" \
                  "$TMPDIR/project/.cargo" \
                  "$TMPDIR/project/lockfile" \
                  "$TMPDIR/registry/3/b"
                cp ${cargoCheckRegistryConfig} "$TMPDIR/registry/config.json"
                cp ${cargoCheckRegistryEntries} "$TMPDIR/registry/3/b/bar"
                git -C "$TMPDIR/registry" init --quiet
                git -C "$TMPDIR/registry" add config.json 3/b/bar
                git -C "$TMPDIR/registry" \
                  -c user.name=check \
                  -c user.email=check@example.invalid \
                  -c commit.gpgSign=false \
                  commit --quiet -m fixture

                cp ${cargoCheckManifest} "$TMPDIR/project/Cargo.toml"
                cp ${./rust/.cargo/config.toml} "$TMPDIR/project/.cargo/config.toml"
                touch "$TMPDIR/project/lib.rs"
                cd "$TMPDIR/project"
                # Cargo's test clock keeps the seven-day boundary deterministic.
                CARGO_HOME="$TMPDIR/cargo-home" \
                  CARGO_RESOLVER_LOCKFILE_PATH="$TMPDIR/project/lockfile/Cargo.lock" \
                  __CARGO_TEST_INVOCATION_TIME="2006-08-08T00:00:00Z" \
                  cargo \
                    --config 'source.crates-io.replace-with="cooldown-fixture"' \
                    --config "source.cooldown-fixture.registry=\"file://$TMPDIR/registry\"" \
                    generate-lockfile
                test -f "$TMPDIR/project/lockfile/Cargo.lock"
                test ! -e "$TMPDIR/project/Cargo.lock"
                grep -A1 -Fx 'name = "bar"' "$TMPDIR/project/lockfile/Cargo.lock" \
                  | grep -Fx 'version = "1.0.0"'

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

          rust-dev-environment = (evalRustDevEnvironment pkgs).config.devInfra.rust.devEnvironment.devShell;
        }
      );
    };
}
