# Override some packages and utilities in 'pkgs'
# and make them available globally via callPackage.
#
# For more details see:
# - https://nixos.wiki/wiki/Overlays
# - https://nixos.org/nixos/nix-pills/callpackage-design-pattern.html

self: super:

let
  inherit (super) stdenv stdenvNoCC callPackage;
in {
  # Fix for MacOS
  mkShell = super.mkShell.override { stdenv = stdenvNoCC; };

  lib = (super.lib or { }) // (import ./lib {
    inherit (super) lib;
  });

  # Checks fail on darwin.
  git-lfs = super.git-lfs.overrideAttrs (old: {
    doCheck = false;
  });

  # Package version adjustments
  nodejs = super.nodejs_20;
  ruby = super.ruby_3_1;
  yarn = super.yarn.override { nodejs = super.nodejs_20; };
  openjdk = super.openjdk17_headless;
  go = super.go_1_21;
  clang = super.clang_15;
  buildGoPackage = super.buildGo121Package;
  buildGoModule = super.buildGo121Module;
  gomobile = (super.gomobile.overrideAttrs (old: {
    patches = [
      (self.fetchurl { # https://github.com/golang/mobile/pull/84
        url = "https://github.com/golang/mobile/commit/f20e966e05b8f7e06bed500fa0da81cf6ebca307.patch";
        sha256 = "sha256-TZ/Yhe8gMRQUZFAs9G5/cf2b9QGtTHRSObBFD5Pbh7Y=";
      })
      (self.fetchurl { # https://github.com/golang/go/issues/58426
        url = "https://github.com/golang/mobile/commit/406ed3a7b8e44dc32844953647b49696d8847d51.patch";
        sha256 = "sha256-dqbYukHkQEw8npOkKykOAzMC3ot/Y4DEuh7fE+ptlr8=";
      })
    ];
  })).override {
    # FIXME: No Android SDK packages for aarch64-darwin.
    withAndroidPkgs = stdenv.system != "aarch64-darwin";
    androidPkgs = self.androidEnvCustom.compose;
  };

  # Android environment
  androidEnvCustom = callPackage ./pkgs/android-sdk { };
  androidPkgs = self.androidEnvCustom.pkgs;
  androidShell = self.androidEnvCustom.shell;
}
