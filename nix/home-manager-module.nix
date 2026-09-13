{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.recall;
  toml = pkgs.formats.toml { };
  settingsFile = toml.generate "recall.toml" {
    storage = {
      max_size = cfg.settings.storage.maxSize;
      auto_prune = cfg.settings.storage.autoPrune;
    };
  };
in
{
  options.programs.recall = {
    enable = lib.mkEnableOption "Recall command and output history for Nushell";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "inputs.recall.packages.${pkgs.stdenv.hostPlatform.system}.default";
      description = "The Recall package to install.";
    };

    settings.storage = {
      maxSize = lib.mkOption {
        type = lib.types.str;
        default = "1 GiB";
        example = "500 MiB";
        description = "Maximum combined size of retained output payloads.";
      };

      autoPrune = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether Recall automatically prunes old outputs above maxSize.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.programs.nushell.enable;
        message = "programs.recall requires programs.nushell.enable = true";
      }
    ];

    home.packages = [ cfg.package ];

    programs.nushell.extraConfig = lib.mkAfter ''
      $env.RECALL_CONFIG_PATH = "${settingsFile}"
      use ${cfg.package}/share/nushell/recall/recall.nu *
      recall init
    '';
  };
}
