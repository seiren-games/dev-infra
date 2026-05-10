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

  cargoCooldownUpdateCommandPattern = lib.concatStringsSep "|" cargoCooldownUpdateCommands;
  cargoCooldownPostCheckCommandPattern = lib.concatStringsSep "|" cargoCooldownPostCheckCommands;

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
      real_cargo_dir="$(dirname "$real_cargo")"
      export PATH="$real_cargo_dir:$PATH"

      args=("$@")
      prefix=()
      command_index=-1
      index=0

      if (( ''${#args[@]} > 0 )) && [[ "''${args[0]}" == +* ]]; then
        prefix+=("''${args[0]}")
        index=1
      fi

      while (( index < ''${#args[@]} )); do
        case "''${args[index]}" in
          -V|--version|--list|-h|--help)
            exec "$real_cargo" "$@"
            ;;
          --explain|-C|--color|--config|-Z)
            if (( index + 1 >= ''${#args[@]} )); then
              exec "$real_cargo" "$@"
            fi
            prefix+=("''${args[index]}" "''${args[index + 1]}")
            index=$((index + 2))
            ;;
          --explain=*|-C*|--color=*|--config=*|-Z*)
            prefix+=("''${args[index]}")
            index=$((index + 1))
            ;;
          -v|-vv|-vvv|--verbose|-q|--quiet|--locked|--offline|--frozen)
            prefix+=("''${args[index]}")
            index=$((index + 1))
            ;;
          -*)
            prefix+=("''${args[index]}")
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
      cooldown_check_args=()

      for (( suffix_index = 0; suffix_index < ''${#suffix[@]}; suffix_index++ )); do
        case "''${suffix[suffix_index]}" in
          --manifest-path)
            if (( suffix_index + 1 < ''${#suffix[@]} )); then
              cooldown_check_args+=("--manifest-path" "''${suffix[suffix_index + 1]}")
              suffix_index=$((suffix_index + 1))
            fi
            ;;
          --manifest-path=*)
            cooldown_check_args+=("''${suffix[suffix_index]}")
            ;;
        esac
      done

      case "$command" in
        ${cargoCooldownUpdateCommandPattern})
          exec "$real_cargo" "''${prefix[@]}" cooldown "$command" "''${suffix[@]}"
          ;;
        ${cargoCooldownPostCheckCommandPattern})
          "$real_cargo" "''${prefix[@]}" cooldown "$command" "''${suffix[@]}" || exit $?
          exec "$real_cargo" "''${prefix[@]}" cooldown "''${cooldown_check_args[@]}" metadata \
            --locked \
            --format-version=1 > /dev/null
          ;;
      esac

      exec "$real_cargo" "''${prefix[@]}" --locked "$command" "''${suffix[@]}"
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
        through cargo-cooldown and adds `--locked` to every other Cargo command.
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
