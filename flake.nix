{
  description = "NWaku build flake";

  nixConfig = {
    extra-substituters = [ "https://nix-cache.status.im/" ];
    extra-trusted-public-keys = [ "nix-cache.status.im-1:x/93lOfLU+duPplwMSBR+OlY4+mo+dCN7n0mr4oPwgY=" ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?rev=0ef228213045d2cdb5a169a95d63ded38670b293";
    zerokit = {
      # FIXME: This is patched v0.8.0, use v0.9.0 when ready.
      url = "github:vacp2p/zerokit?rev=818079b8b05d72e1dd03f314522e41a890d0dead";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, zerokit }:
    let
      stableSystems = [
        "x86_64-linux" "aarch64-linux"
        "x86_64-darwin" "aarch64-darwin"
        "x86_64-windows" "i686-linux"
        "i686-windows"
      ];

      forAllSystems = f: nixpkgs.lib.genAttrs stableSystems (system: f system);

      pkgsFor = forAllSystems (
        system: import nixpkgs {
          inherit system;
          config = {
            android_sdk.accept_license = true;
            allowUnfree = true;
          };
          overlays =  [
            (final: prev: {
              androidEnvCustom = prev.callPackage ./nix/pkgs/android-sdk { };
              androidPkgs = final.androidEnvCustom.pkgs;
              androidShell = final.androidEnvCustom.shell;
            })
          ];
        }
      );

    in rec {
      packages = forAllSystems (system: let
        pkgs = pkgsFor.${system};
      in rec {
        libwaku-android-arm64 = pkgs.callPackage ./nix/default.nix {
          inherit stableSystems;
          src = self;
          targets = ["libwaku-android-arm64"];
          abidir = "arm64-v8a";
          zerokitRln = zerokit.packages.${system}.rln-android-arm64;
        };

        wakucanary = pkgs.callPackage ./nix/default.nix {
          inherit stableSystems;
          src = self;
          targets = ["wakucanary"];
          zerokitRln = zerokit.packages.${system}.rln;
        };

        default = libwaku-android-arm64;
      });

      devShells = forAllSystems (system: {
        default = pkgsFor.${system}.callPackage ./nix/shell.nix {};
      });
    };
}
