{
  description = "Development infrastructure shared files";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { nixpkgs, ... }:
    let
      rustDevEnvironmentModule = import ./rust/nix/modules/dev-environment.nix;

      # nixpkgs-unstable no longer supports x86_64-darwin. Consumers using a
      # compatible nixpkgs revision can still evaluate the shared Rust module.
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
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

          rust-cli-tools =
            pkgs.runCommand "rust-cli-tools-check"
              {
                nativeBuildInputs = [ rustDevEnvironmentPackage ];
              }
              ''
                cargo-audit --version \
                  | grep -Fx 'cargo-audit ${pkgs.cargo-audit.version}'
                test "$(readlink -f "$(command -v rustc)")" \
                  = "$(readlink -f ${pkgs.rustc}/bin/rustc)"
                test "$(readlink -f "$(command -v cargo-clippy)")" \
                  = "$(readlink -f ${pkgs.clippy}/bin/cargo-clippy)"
                test "$(readlink -f "$(command -v cargo-fmt)")" \
                  = "$(readlink -f ${pkgs.rustfmt}/bin/cargo-fmt)"
                tombi --version \
                  | grep -F 'tombi ${pkgs.tombi.version} '
                touch "$out"
              '';

          rust-envrc = pkgs.runCommand "rust-envrc-check" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
            shellcheck ${./rust/.envrc}
            shellcheck ${./rust/scripts/check-rust-toolchain-freshness}
            touch "$out"
          '';

          rust-toolchain-freshness =
            pkgs.runCommand "rust-toolchain-freshness-check"
              {
                nativeBuildInputs = [ rustDevEnvironmentPackage ];
              }
              ''
                cat > manifests.txt <<'EOF'
                static.rust-lang.org/dist/2026-05-28/channel-rust-1.96.0.toml
                static.rust-lang.org/dist/2026-06-30/channel-rust-1.96.1.toml
                static.rust-lang.org/dist/2026-07-09/channel-rust-1.97.0.toml
                static.rust-lang.org/dist/2026-07-16/channel-rust-1.97.1.toml
                static.rust-lang.org/dist/2026-08-20/channel-rust-1.98.0.toml
                EOF

                check_freshness() {
                  check-rust-toolchain-freshness \
                    --manifest-list manifests.txt \
                    --current-date "$1" \
                    --rustc-version "$2"
                }

                # The 30-day boundary is inclusive: 1.97.0 becomes required on August 8.
                check_freshness 2026-08-07 1.96.1
                if check_freshness 2026-08-08 1.96.1; then
                  echo "rustc 1.96.1 must be rejected after the 1.97.0 grace period" >&2
                  exit 1
                fi
                check_freshness 2026-08-08 1.97.0

                # A new release must not reset the requirement for older releases.
                if check_freshness 2026-08-21 1.96.1; then
                  echo "a fresh 1.98.0 release must not make rustc 1.96.1 acceptable" >&2
                  exit 1
                fi
                check_freshness 2026-08-21 1.97.1

                # Patch releases become mandatory independently after their own grace period.
                if check_freshness 2026-08-15 1.97.0; then
                  echo "rustc 1.97.0 must be rejected after the 1.97.1 grace period" >&2
                  exit 1
                fi
                check_freshness 2026-08-15 1.97.1

                if check-rust-toolchain-freshness \
                  --manifest-list manifests.txt \
                  --current-date invalid \
                  --rustc-version 1.97.1; then
                  echo "an invalid current date must be rejected" >&2
                  exit 1
                fi

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
        // nixpkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          rust-shared-files-sync =
            pkgs.runCommand "rust-shared-files-sync-check"
              {
                nativeBuildInputs = [ pkgs.python3 ];
              }
              ''
                DEV_INFRA_TEST_ROOT=${./.} \
                  python3 -B -m unittest discover -s ${./tests} -p 'test_*.py' -v
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
