{
  description = "NWaku build flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    zerokit = {
      url = "github:vacp2p/zerokit?rev=4479810968b88d0ef92717524adf5edd23df1869";
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
          targets = ["libwaku-android-arm64"]; 
          androidArch = "aarch64-linux-android";
          zerokitPkg = zerokit.packages.${system}.zerokit-android-arm64;
        };
        libwaku-android-amd64 = pkgs.callPackage ./nix/default.nix { 
          inherit stableSystems;
          targets = ["libwaku-android-amd64"]; 
          androidArch = "musl64";
          zerokitPkg = zerokit.packages.${system}.zerokit-android-amd64;
        };
        default = libwaku-android-arm64;
      });

      devShells = forAllSystems (system: {
        default = pkgsFor.${system}.callPackage ./nix/shell.nix { };
      });
    };
}