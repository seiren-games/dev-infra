{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.devInfra.rust.ciTools;
in
{
  options.devInfra.rust.ciTools = {
    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [
        cargo-edit
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
