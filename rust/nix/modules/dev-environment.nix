# このファイルを各リポジトリに配置する必要はありません。

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.devInfra.rust.devEnvironment;

  # Keep these values in sync with the official dated Rust nightly channel manifest.
  # `commit` is Cargo's commit reported by `cargo --version --verbose`.
  nightlyCargoRelease = {
    date = "2026-07-20";
    version = "1.99.0-nightly";
    commit = "3efb1f477e99b42974b982d939fd100303cdf7db";
    hashes = {
      aarch64-apple-darwin = "sha256-H1LnQ5uaXXnhU8hpebHoWbMYC2lFRSCrTpx/YYtpBdA=";
      aarch64-unknown-linux-gnu = "sha256-/VPhPdY2ONWdjEP0DaYLBlBVGRbDxw8/FvfsoPcv7CU=";
      x86_64-apple-darwin = "sha256-fbS9qjc04KJtkUZBtd/TM20tcSU4ZsUQheBXe/TrA6w=";
      x86_64-unknown-linux-gnu = "sha256-TlUA/GIDTTtCRQqSH0CO6eSqzV5t5Sp4/XNtYhWImjg=";
    };
  };

  nightlyCargoTarget = pkgs.stdenv.hostPlatform.rust.rustcTarget;
  nightlyCargoHash =
    nightlyCargoRelease.hashes.${nightlyCargoTarget}
      or (throw "nightly Cargo is not available for ${nightlyCargoTarget}");

  nightlyCargo = pkgs.stdenv.mkDerivation {
    pname = "cargo-nightly";
    version = "${nightlyCargoRelease.version}-${nightlyCargoRelease.date}";

    src = pkgs.fetchurl {
      url = "https://static.rust-lang.org/dist/${nightlyCargoRelease.date}/cargo-nightly-${nightlyCargoTarget}.tar.xz";
      hash = nightlyCargoHash;
    };

    nativeBuildInputs = lib.optional (!pkgs.stdenv.hostPlatform.isDarwin) pkgs.autoPatchelfHook;
    buildInputs = [ pkgs.bash ] ++ lib.optional (!pkgs.stdenv.hostPlatform.isDarwin) pkgs.gcc.cc.lib;

    postPatch = ''
      patchShebangs .
    '';

    installPhase = ''
      runHook preInstall

      ./install.sh --prefix="$out" --components=cargo
    ''
    + lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
      install_name_tool -change "/usr/lib/libcurl.4.dylib" \
        "${lib.getLib pkgs.curl}/lib/libcurl.4.dylib" "$out/bin/cargo"
    ''
    + ''
      runHook postInstall
    '';

    passthru = {
      inherit (nightlyCargoRelease) commit date;
    };

    meta = {
      homepage = "https://doc.rust-lang.org/cargo/";
      description = "Nightly Cargo with min-publish-age support";
      mainProgram = "cargo";
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
      license = [
        lib.licenses.mit
        lib.licenses.asl20
      ];
      platforms = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];
    };
  };
in
{
  options.devInfra.rust.devEnvironment = {
    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [
        cargo-cross
      ];
      description = ''
        Additional tool packages exposed by the shared Rust development environment.
      '';
    };

    cargoPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = ''
        Pinned nightly Cargo required to enforce the shared dependency publish-age policy.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = ''
        Internal combined PATH used by the shared Rust development shell.
      '';
    };

    devShell = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = ''
        Project-scoped development shell that puts the pinned nightly Cargo on PATH.
      '';
    };
  };

  config.devInfra.rust.devEnvironment = {
    cargoPackage = nightlyCargo;

    package = pkgs.buildEnv {
      name = "dev-infra-rust-dev-environment";
      paths = [ (lib.hiPrio cfg.cargoPackage) ] ++ cfg.packages;
    };

    devShell = pkgs.mkShell {
      name = "dev-infra-rust-dev-environment";
      packages = [ cfg.package ];

      DEV_INFRA_RUST_NIGHTLY_CARGO_COMMIT = cfg.cargoPackage.commit;
    };
  };
}
