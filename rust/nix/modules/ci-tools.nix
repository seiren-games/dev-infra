# このファイルは https://github.com/seiren-games/dev-infra で管理されています。様々なリポジトリで共有することが目的のファイルです。

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.devInfra.rust.ciTools;
  cargoCooldownSrc = pkgs.fetchFromGitHub {
    owner = "dertin";
    repo = "cargo-cooldown";
    rev = "8842ef458a4fcd5eb4cc93c6f1f40e7bd35ff01b";
    hash = "sha256-4tOvuOO8O7s6vGLYlOY+f/ouxibUNCo7CCwkJuTGqvw=";
  };

  cargoCooldown = pkgs.rustPlatform.buildRustPackage {
    pname = "cargo-cooldown";
    version = "0.3.0";

    src = cargoCooldownSrc;

    cargoHash = "sha256-AlOAF0XbbLG572lfkTJ2BJY8OgHnGujf4PMiAaytnc0=";

    nativeCheckInputs = [
      pkgs.cacert
    ];

    preCheck = ''
      export XDG_CACHE_HOME="$TMPDIR/.cache"
      export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
    '';
  };
in
{
  options.devInfra.rust.ciTools = {
    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [
        cargo-edit
        cargoCooldown
      ];
      description = ''
        Tool packages required by the shared Rust CI workflow.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = ''
        Combined package exposing the shared Rust CI tools on PATH.
      '';
    };
  };

  config.devInfra.rust.ciTools.package = pkgs.buildEnv {
    name = "dev-infra-rust-ci-tools";
    paths = cfg.packages;
  };
}
