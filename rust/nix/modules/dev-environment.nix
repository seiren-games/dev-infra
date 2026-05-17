# このファイルは https://github.com/seiren-games/dev-infra で管理されています。様々なリポジトリで共有することが目的のファイルです。

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.devInfra.rust.devEnvironment;

  cargoCooldownUpdateCommands = [
    "update"
  ];

  cargoCooldownPostCheckCommands = [
    "add"
    "remove"
    "rm"
    "upgrade"
    "generate-lockfile"
    "fetch"
  ];

  cargoLockingCommands = [
    "b"
    "bench"
    "build"
    "c"
    "check"
    "clippy"
    "d"
    "doc"
    "fix"
    "install"
    "metadata"
    "package"
    "publish"
    "r"
    "report"
    "run"
    "rustc"
    "rustdoc"
    "t"
    "test"
    "tree"
    "vendor"
  ];

  cargoCooldownUpdateCommandPattern = lib.concatStringsSep "|" cargoCooldownUpdateCommands;
  cargoCooldownPostCheckCommandPattern = lib.concatStringsSep "|" cargoCooldownPostCheckCommands;
  cargoLockingCommandPattern = lib.concatStringsSep "|" cargoLockingCommands;
  cargoCooldownPolicy = builtins.fromTOML (builtins.readFile ../../cooldown.toml);

  cargoCooldown = pkgs.rustPlatform.buildRustPackage rec {
    pname = "cargo-cooldown";
    version = "0.3.0";

    src = pkgs.fetchCrate {
      inherit pname version;
      hash = "sha256-HW278EsisPZWxl0N7SLUCB7OR7tgyCPL6Z1Q/DSNhFw=";
    };

    patches = [
      (pkgs.writeText "cargo-cooldown-external-path-dependencies.patch" ''
        diff --git a/src/isolation.rs b/src/isolation.rs
        index d082f07..4028876 100644
        --- a/src/isolation.rs
        +++ b/src/isolation.rs
        @@ -15,6 +15,7 @@ use std::time::{SystemTime, UNIX_EPOCH};
         use anyhow::{Context, Result, bail};
         use clap_cargo::Manifest;
         use tempfile::{Builder, TempDir};
        +use toml::Value;
         use tracing::{debug, warn};

         use crate::project::ProjectContext;
        @@ -46,6 +47,7 @@ impl IsolatedWorkspace {
                     &workspace_root,
                     &project.target_directory,
                 )?;
        +        rewrite_external_path_dependencies(&project.workspace_root, &workspace_root)?;

                 let current_dir = map_current_dir(project, &workspace_root)?;
                 let manifest = map_manifest(project, manifest, &workspace_root)?;
        @@ -523,6 +525,173 @@ fn target_directory_to_skip(workspace_root: &Path, target_directory: &Path) -> O
                 .then_some(target_directory)
         }

        +fn rewrite_external_path_dependencies(
        +    source_workspace_root: &Path,
        +    temp_workspace_root: &Path,
        +) -> Result<()> {
        +    let source_workspace_root = canonicalize_existing(source_workspace_root)?;
        +    rewrite_external_path_dependencies_in_dir(
        +        &source_workspace_root,
        +        temp_workspace_root,
        +        temp_workspace_root,
        +    )
        +}
        +
        +fn rewrite_external_path_dependencies_in_dir(
        +    source_workspace_root: &Path,
        +    temp_workspace_root: &Path,
        +    current_dir: &Path,
        +) -> Result<()> {
        +    for entry in fs::read_dir(current_dir)
        +        .with_context(|| format!("failed to read directory {}", current_dir.display()))?
        +    {
        +        let entry =
        +            entry.with_context(|| format!("failed to read entry in {}", current_dir.display()))?;
        +        let path = entry.path();
        +        let file_type = entry
        +            .file_type()
        +            .with_context(|| format!("failed to inspect {}", path.display()))?;
        +
        +        if file_type.is_dir() {
        +            rewrite_external_path_dependencies_in_dir(
        +                source_workspace_root,
        +                temp_workspace_root,
        +                &path,
        +            )?;
        +        } else if file_type.is_file() && entry.file_name() == OsStr::new("Cargo.toml") {
        +            rewrite_external_path_dependencies_in_manifest(
        +                source_workspace_root,
        +                temp_workspace_root,
        +                &path,
        +            )?;
        +        }
        +    }
        +
        +    Ok(())
        +}
        +
        +fn rewrite_external_path_dependencies_in_manifest(
        +    source_workspace_root: &Path,
        +    temp_workspace_root: &Path,
        +    temp_manifest_path: &Path,
        +) -> Result<()> {
        +    let relative_manifest = temp_manifest_path
        +        .strip_prefix(temp_workspace_root)
        +        .with_context(|| {
        +            format!(
        +                "temporary manifest {} is outside temporary workspace {}",
        +                temp_manifest_path.display(),
        +                temp_workspace_root.display()
        +            )
        +        })?;
        +    let source_manifest_path = source_workspace_root.join(relative_manifest);
        +    let source_manifest_dir = source_manifest_path.parent().with_context(|| {
        +        format!(
        +            "source manifest {} does not have a parent directory",
        +            source_manifest_path.display()
        +        )
        +    })?;
        +
        +    let contents = fs::read_to_string(temp_manifest_path)
        +        .with_context(|| format!("failed to read manifest {}", temp_manifest_path.display()))?;
        +    let mut manifest: Value = toml::from_str(&contents)
        +        .with_context(|| format!("failed to parse manifest {}", temp_manifest_path.display()))?;
        +    let changed = rewrite_external_path_dependencies_in_manifest_value(
        +        &mut manifest,
        +        &source_workspace_root,
        +        source_manifest_dir,
        +    )?;
        +
        +    if changed {
        +        fs::write(temp_manifest_path, toml::to_string_pretty(&manifest)?)
        +            .with_context(|| format!("failed to write manifest {}", temp_manifest_path.display()))?;
        +    }
        +
        +    Ok(())
        +}
        +
        +fn rewrite_external_path_dependencies_in_manifest_value(
        +    manifest: &mut Value,
        +    source_workspace_root: &Path,
        +    source_manifest_dir: &Path,
        +) -> Result<bool> {
        +    let Some(root_table) = manifest.as_table_mut() else {
        +        return Ok(false);
        +    };
        +
        +    let mut changed = false;
        +    for table_name in ["dependencies", "dev-dependencies", "build-dependencies"] {
        +        if let Some(dependencies) = root_table.get_mut(table_name) {
        +            changed |= rewrite_external_path_dependency_table(
        +                dependencies,
        +                source_workspace_root,
        +                source_manifest_dir,
        +            )?;
        +        }
        +    }
        +
        +    if let Some(workspace) = root_table.get_mut("workspace").and_then(Value::as_table_mut) {
        +        for table_name in ["dependencies", "dev-dependencies", "build-dependencies"] {
        +            if let Some(dependencies) = workspace.get_mut(table_name) {
        +                changed |= rewrite_external_path_dependency_table(
        +                    dependencies,
        +                    source_workspace_root,
        +                    source_manifest_dir,
        +                )?;
        +            }
        +        }
        +    }
        +
        +    if let Some(targets) = root_table.get_mut("target").and_then(Value::as_table_mut) {
        +        for target in targets.iter_mut().filter_map(|(_, value)| value.as_table_mut()) {
        +            for table_name in ["dependencies", "dev-dependencies", "build-dependencies"] {
        +                if let Some(dependencies) = target.get_mut(table_name) {
        +                    changed |= rewrite_external_path_dependency_table(
        +                        dependencies,
        +                        source_workspace_root,
        +                        source_manifest_dir,
        +                    )?;
        +                }
        +            }
        +        }
        +    }
        +
        +    Ok(changed)
        +}
        +
        +fn rewrite_external_path_dependency_table(
        +    dependencies: &mut Value,
        +    source_workspace_root: &Path,
        +    source_manifest_dir: &Path,
        +) -> Result<bool> {
        +    let Some(dependency_table) = dependencies.as_table_mut() else {
        +        return Ok(false);
        +    };
        +
        +    let mut changed = false;
        +    for dependency in dependency_table.iter_mut().filter_map(|(_, value)| value.as_table_mut()) {
        +        let Some(path) = dependency.get("path").and_then(Value::as_str) else {
        +            continue;
        +        };
        +        if Path::new(path).is_absolute() {
        +            continue;
        +        }
        +
        +        let absolute_path = canonicalize_existing(&source_manifest_dir.join(path))?;
        +        if absolute_path.starts_with(source_workspace_root) {
        +            continue;
        +        }
        +
        +        dependency.insert(
        +            "path".to_string(),
        +            Value::String(absolute_path.to_string_lossy().into_owned()),
        +        );
        +        changed = true;
        +    }
        +
        +    Ok(changed)
        +}
        +
         #[cfg(unix)]
         fn copy_symlink(source: &Path, destination: &Path) -> Result<()> {
             let target = fs::read_link(source)
        @@ -630,4 +799,41 @@ mod tests {
                     "keep"
                 );
             }
        +
        +    #[test]
        +    fn workspace_copy_rewrites_external_path_dependencies_to_absolute_paths() {
        +        let temp_dir = tempfile::tempdir().expect("tempdir should build");
        +        let source = temp_dir.path().join("source");
        +        let external = temp_dir.path().join("external");
        +        let destination = temp_dir.path().join("destination");
        +        fs::create_dir_all(source.join("app")).expect("app dir should be creatable");
        +        fs::create_dir_all(&external).expect("external dep dir should be creatable");
        +        fs::write(
        +            source.join("app/Cargo.toml"),
        +            r#"
        +[package]
        +name = "app"
        +version = "0.1.0"
        +
        +[dependencies]
        +dep = { path = "../../external" }
        +"#,
        +        )
        +        .expect("app manifest should be writable");
        +        fs::write(
        +            external.join("Cargo.toml"),
        +            r#"
        +[package]
        +name = "dep"
        +version = "0.1.0"
        +"#,
        +        )
        +        .expect("external manifest should be writable");
        +
        +        copy_workspace(&source, &destination, &source.join("target")).expect("workspace should copy");
        +        rewrite_external_path_dependencies(&source, &destination).expect("paths should rewrite");
        +
        +        let rewritten = fs::read_to_string(destination.join("app/Cargo.toml")).unwrap();
        +        assert!(rewritten.contains(&format!("path = \"{}\"", external.display())));
        +    }
         }
      '')
    ];

    cargoHash = "sha256-AlOAF0XbbLG572lfkTJ2BJY8OgHnGujf4PMiAaytnc0=";

    nativeCheckInputs = [
      pkgs.cacert
    ];

    preCheck = ''
      export HOME="$TMPDIR"
      export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
    '';
  };

  cargoPolicyWrapper = pkgs.writeShellApplication {
    name = "cargo";
    runtimeInputs = [
      cargoCooldown
      pkgs.coreutils
    ];
    text = ''
      find_real_cargo() {
        local self
        self="$(readlink -f "$0")"

        local candidate candidate_resolved
        while IFS= read -r candidate; do
          candidate_resolved="$(readlink -f "$candidate")"
          if [[ "$candidate_resolved" != "$self" ]]; then
            printf '%s\n' "$candidate"
            return 0
          fi
        done < <(type -ap cargo)

        printf 'dev-infra cargo wrapper: real cargo was not found on PATH\n' >&2
        return 127
      }

      real_cargo="$(find_real_cargo)"
      export DEV_INFRA_REAL_CARGO="$real_cargo"
      export PATH="${realCargoShim}/bin:$PATH"

      has_cargo_locking_arg() {
        local arg

        for arg in "$@"; do
          case "$arg" in
            --)
              return 1
              ;;
            --locked|--frozen)
              return 0
              ;;
          esac
        done

        return 1
      }

      has_cargo_dry_run_arg() {
        local arg

        for arg in "$@"; do
          case "$arg" in
            --)
              return 1
              ;;
            --dry-run)
              return 0
              ;;
          esac
        done

        return 1
      }

      command_accepts_cargo_locking_arg() {
        case "$1" in
          ${cargoLockingCommandPattern})
            return 0
            ;;
          *)
            return 1
            ;;
        esac
      }

      cooldown_policy_env=(
        "COOLDOWN_MINUTES=${toString cargoCooldownPolicy.cooldown_minutes}"
        "COOLDOWN_ENFORCEMENT=${cargoCooldownPolicy.enforcement}"
        "COOLDOWN_LOCKFILE_BASELINE=${cargoCooldownPolicy.lockfile_baseline}"
      )

      args=("$@")
      cargo_invocation_args=()
      command_prefix_args=()
      command_index=-1
      index=0

      if (( ''${#args[@]} > 0 )) && [[ "''${args[0]}" == +* ]]; then
        cargo_invocation_args+=("''${args[0]}")
        index=1
      fi

      while (( index < ''${#args[@]} )); do
        case "''${args[index]}" in
          -V|--version|--list|-h|--help)
            exec "$real_cargo" "$@"
            ;;
          --explain)
            if (( index + 1 >= ''${#args[@]} )); then
              exec "$real_cargo" "$@"
            fi
            cargo_invocation_args+=("''${args[index]}" "''${args[index + 1]}")
            index=$((index + 2))
            ;;
          --explain=*)
            cargo_invocation_args+=("''${args[index]}")
            index=$((index + 1))
            ;;
          -C)
            if (( index + 1 >= ''${#args[@]} )); then
              exec "$real_cargo" "$@"
            fi
            cargo_invocation_args+=("''${args[index]}" "''${args[index + 1]}")
            index=$((index + 2))
            ;;
          -C*)
            cargo_invocation_args+=("''${args[index]}")
            index=$((index + 1))
            ;;
          --color|--config|-Z)
            if (( index + 1 >= ''${#args[@]} )); then
              exec "$real_cargo" "$@"
            fi
            command_prefix_args+=("''${args[index]}" "''${args[index + 1]}")
            index=$((index + 2))
            ;;
          --color=*|--config=*|-Z*)
            command_prefix_args+=("''${args[index]}")
            index=$((index + 1))
            ;;
          -v|-vv|-vvv|--verbose|-q|--quiet|--locked|--offline|--frozen)
            command_prefix_args+=("''${args[index]}")
            index=$((index + 1))
            ;;
          -*)
            cargo_invocation_args+=("''${args[index]}")
            index=$((index + 1))
            ;;
          *)
            command_index=$index
            break
            ;;
        esac
      done

      if (( command_index == -1 )); then
        exec "$real_cargo" "$@"
      fi

      command="''${args[command_index]}"
      suffix=("''${args[@]:command_index + 1}")
      cooldown_command_args=("$command" "''${command_prefix_args[@]}" "''${suffix[@]}")
      cooldown_metadata_args=(--all-features)
      cargo_lock_args=()

      if command_accepts_cargo_locking_arg "$command" \
        && ! has_cargo_locking_arg "''${command_prefix_args[@]}" \
        && ! has_cargo_locking_arg "''${suffix[@]}"; then
        cargo_lock_args=(--locked)
      fi

      for suffix_arg in "''${suffix[@]}"; do
        case "$suffix_arg" in
          --)
            break
            ;;
          -h|--help)
            exec "$real_cargo" "$@"
            ;;
        esac
      done

      for (( suffix_index = 0; suffix_index < ''${#suffix[@]}; suffix_index++ )); do
        case "''${suffix[suffix_index]}" in
          --)
            break
            ;;
          --offline|--frozen)
            cooldown_metadata_args+=("''${suffix[suffix_index]}")
            ;;
          --all-features)
            ;;
          --manifest-path)
            if (( suffix_index + 1 < ''${#suffix[@]} )); then
              cooldown_metadata_args+=("''${suffix[suffix_index]}" "''${suffix[suffix_index + 1]}")
              suffix_index=$((suffix_index + 1))
            fi
            ;;
          --manifest-path=*)
            cooldown_metadata_args+=("''${suffix[suffix_index]}")
            ;;
        esac
      done

      case "$command" in
        ${cargoCooldownUpdateCommandPattern}|${cargoCooldownPostCheckCommandPattern})
          if has_cargo_dry_run_arg "''${suffix[@]}"; then
            exec "$real_cargo" "''${cargo_invocation_args[@]}" \
              "''${command_prefix_args[@]}" \
              "$command" \
              "''${suffix[@]}"
          fi
          ;;
      esac

      case "$command" in
        ${cargoCooldownUpdateCommandPattern})
          exec env "''${cooldown_policy_env[@]}" "$real_cargo" "''${cargo_invocation_args[@]}" \
            cooldown \
            "''${cooldown_command_args[@]}"
          ;;
        ${cargoCooldownPostCheckCommandPattern})
          env "''${cooldown_policy_env[@]}" "$real_cargo" "''${cargo_invocation_args[@]}" \
            cooldown \
            "''${cooldown_command_args[@]}" || exit $?
          exec env "''${cooldown_policy_env[@]}" "$real_cargo" "''${cargo_invocation_args[@]}" \
            cooldown \
            metadata \
            "''${command_prefix_args[@]}" \
            --locked \
            --format-version=1 \
            "''${cooldown_metadata_args[@]}" > /dev/null
          ;;
      esac

      exec "$real_cargo" "''${cargo_invocation_args[@]}" \
        "''${command_prefix_args[@]}" \
        "$command" \
        "''${cargo_lock_args[@]}" \
        "''${suffix[@]}"
    '';
  };

  realCargoShim = pkgs.writeShellApplication {
    name = "cargo";
    text = ''
      exec "$DEV_INFRA_REAL_CARGO" "$@"
    '';
  };
in
{
  options.devInfra.rust.devEnvironment = {
    cargoPackage = lib.mkOption {
      type = lib.types.package;
      default = cargoPolicyWrapper;
      readOnly = true;
      description = ''
        Cargo policy wrapper. It runs manifest or lockfile update commands
        through cargo-cooldown and adds `--locked` to known Cargo commands
        that accept lockfile flags.
      '';
    };

    cargoCooldownPackage = lib.mkOption {
      type = lib.types.package;
      default = cargoCooldown;
      readOnly = true;
      description = ''
        Pinned cargo-cooldown package used by the shared Rust development
        environment.
      '';
    };

    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [
        cargo-edit
        cargo-cross
      ];
      description = ''
        Tool packages required by the shared Rust development environment.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = ''
        Combined package exposing the shared Rust development tools on PATH.
      '';
    };
  };

  config.devInfra.rust.devEnvironment.package = pkgs.buildEnv {
    name = "dev-infra-rust-dev-environment";
    paths = [
      (lib.hiPrio cfg.cargoPackage)
      cfg.cargoCooldownPackage
    ] ++ cfg.packages;
  };
}
