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

      collect_cargo_cooldown_constraint_args() {
        local arg

        for arg in "$@"; do
          case "$arg" in
            --)
              return 0
              ;;
            --locked)
              cargo_cooldown_locked=true
              ;;
            --offline)
              cargo_cooldown_offline=true
              ;;
            --frozen)
              cargo_cooldown_locked=true
              cargo_cooldown_offline=true
              ;;
          esac
        done
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
      cooldown_post_check_command=metadata
      cooldown_post_check_lock_args=()
      cooldown_post_check_args=()
      cooldown_post_check_selector_args=()
      cooldown_post_check_needs_package_selection=false
      cargo_lock_args=()
      cargo_cooldown_locked=false
      cargo_cooldown_offline=false

      collect_cargo_cooldown_constraint_args "''${command_prefix_args[@]}"
      collect_cargo_cooldown_constraint_args "''${suffix[@]}"

      if [[ "$cargo_cooldown_locked" != true ]]; then
        cooldown_post_check_lock_args=(--locked)
      fi

      cooldown_post_check_args=("''${cooldown_post_check_lock_args[@]}" --format-version=1 --all-features)

      cargo_cooldown_shim_env=(
        "DEV_INFRA_CARGO_COOLDOWN_LOCKED=$cargo_cooldown_locked"
        "DEV_INFRA_CARGO_COOLDOWN_OFFLINE=$cargo_cooldown_offline"
      )

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
            cooldown_post_check_selector_args+=("''${suffix[suffix_index]}")
            ;;
          --all-features)
            ;;
          -p|--package)
            if (( suffix_index + 1 < ''${#suffix[@]} )); then
              cooldown_post_check_selector_args+=("''${suffix[suffix_index]}" "''${suffix[suffix_index + 1]}")
              cooldown_post_check_needs_package_selection=true
              suffix_index=$((suffix_index + 1))
            fi
            ;;
          -p*)
            cooldown_post_check_selector_args+=("''${suffix[suffix_index]}")
            cooldown_post_check_needs_package_selection=true
            ;;
          --package=*)
            cooldown_post_check_selector_args+=("''${suffix[suffix_index]}")
            cooldown_post_check_needs_package_selection=true
            ;;
          --workspace)
            cooldown_post_check_selector_args+=("''${suffix[suffix_index]}")
            cooldown_post_check_needs_package_selection=true
            ;;
          --all)
            cooldown_post_check_selector_args+=(--workspace)
            cooldown_post_check_needs_package_selection=true
            ;;
          --exclude)
            if (( suffix_index + 1 < ''${#suffix[@]} )); then
              cooldown_post_check_selector_args+=("''${suffix[suffix_index]}" "''${suffix[suffix_index + 1]}")
              cooldown_post_check_needs_package_selection=true
              suffix_index=$((suffix_index + 1))
            fi
            ;;
          --exclude=*)
            cooldown_post_check_selector_args+=("''${suffix[suffix_index]}")
            cooldown_post_check_needs_package_selection=true
            ;;
          --manifest-path)
            if (( suffix_index + 1 < ''${#suffix[@]} )); then
              cooldown_post_check_selector_args+=("''${suffix[suffix_index]}" "''${suffix[suffix_index + 1]}")
              suffix_index=$((suffix_index + 1))
            fi
            ;;
          --manifest-path=*)
            cooldown_post_check_selector_args+=("''${suffix[suffix_index]}")
            ;;
        esac
      done

      if [[ "$cooldown_post_check_needs_package_selection" == true ]]; then
        cooldown_post_check_command=tree
        cooldown_post_check_args=("''${cooldown_post_check_lock_args[@]}" --all-features --depth 0)
      fi

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
          exec env "''${cooldown_policy_env[@]}" "''${cargo_cooldown_shim_env[@]}" "$real_cargo" "''${cargo_invocation_args[@]}" \
            cooldown \
            "''${cooldown_command_args[@]}"
          ;;
        ${cargoCooldownPostCheckCommandPattern})
          env "''${cooldown_policy_env[@]}" "''${cargo_cooldown_shim_env[@]}" "$real_cargo" "''${cargo_invocation_args[@]}" \
            cooldown \
            "''${cooldown_command_args[@]}" || exit $?
          exec env "''${cooldown_policy_env[@]}" "''${cargo_cooldown_shim_env[@]}" "$real_cargo" "''${cargo_invocation_args[@]}" \
            cooldown \
            "$cooldown_post_check_command" \
            "''${command_prefix_args[@]}" \
            "''${cooldown_post_check_args[@]}" \
            "''${cooldown_post_check_selector_args[@]}" > /dev/null
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
      has_cargo_arg() {
        local expected="$1"
        shift

        local arg
        for arg in "$@"; do
          case "$arg" in
            --)
              return 1
              ;;
            "$expected")
              return 0
              ;;
          esac
        done

        return 1
      }

      cargo_constraint_args=()

      if [[ "''${DEV_INFRA_CARGO_COOLDOWN_LOCKED:-false}" == true ]] \
        && ! has_cargo_arg --locked "$@" \
        && ! has_cargo_arg --frozen "$@"; then
        cargo_constraint_args+=(--locked)
      fi

      if [[ "''${DEV_INFRA_CARGO_COOLDOWN_OFFLINE:-false}" == true ]] \
        && ! has_cargo_arg --offline "$@" \
        && ! has_cargo_arg --frozen "$@"; then
        cargo_constraint_args+=(--offline)
      fi

      exec "$DEV_INFRA_REAL_CARGO" "''${cargo_constraint_args[@]}" "$@"
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
