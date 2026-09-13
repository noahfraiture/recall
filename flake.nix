{
  description = "Searchable command and output history for Nushell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.stdenvNoCC.mkDerivation {
            pname = "recall";
            version = "0.1.0";
            src = nixpkgs.lib.cleanSource ./.;

            dontBuild = true;
            doCheck = true;
            nativeCheckInputs = [ pkgs.nushell ];

            checkPhase = ''
              runHook preCheck
              nu --no-config-file --no-history tests/test_recall.nu
              runHook postCheck
            '';

            installPhase = ''
              runHook preInstall
              install -Dm444 recall.nu "$out/share/nushell/recall/recall.nu"
              install -Dm444 recall.example.toml "$out/share/doc/recall/recall.example.toml"
              install -Dm444 README.md "$out/share/doc/recall/README.md"
              install -Dm444 LICENSE "$out/share/doc/recall/LICENSE"
              runHook postInstall
            '';

            meta = {
              description = "Searchable command and output history for Nushell";
              homepage = "https://github.com/noahfraiture/recall";
              license = nixpkgs.lib.licenses.mit;
              platforms = nixpkgs.lib.platforms.unix;
            };
          };
        }
      );

      checks = forAllSystems (system: {
        package = self.packages.${system}.default;
      });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);

      devShells = forAllSystems (system: {
        default = nixpkgs.legacyPackages.${system}.mkShell {
          packages = [ nixpkgs.legacyPackages.${system}.nushell ];
        };
      });

      homeManagerModules.default = import ./nix/home-manager-module.nix { inherit self; };
    };
}
