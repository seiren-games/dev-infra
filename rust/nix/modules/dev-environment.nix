# このファイルは https://github.com/seiren-games/dev-infra で管理されています。様々なリポジトリで共有することが目的のファイルです。

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.devInfra.rust.devEnvironment;
in
{
  options.devInfra.rust.devEnvironment = {
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
    paths = cfg.packages;
  };
}
