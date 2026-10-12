{
  description = "Retry and resume Codex CLI sessions after usage limits recover";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          codexwait = pkgs.callPackage ./package.nix { };
        in {
          default = codexwait;
          inherit codexwait;
        });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.codexwait}/bin/codexwait";
        };
      });

      checks = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; };
        in {
          shellcheck = pkgs.runCommand "codexwait-shellcheck" {
            nativeBuildInputs = [ pkgs.shellcheck ];
          } ''
            shellcheck ${./src/codexwait.sh}
            touch $out
          '';
        });
    };
}
