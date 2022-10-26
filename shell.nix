{ pkgs ? import (builtins.fetchTarball {
  url = "https://github.com/NixOS/nixpkgs/archive/dbf1d73cd1a17276196afeee169b4cf7834b7a96.tar.gz";
  sha256 = "sha256:1k5nvn2yzw370cqsfh62lncsgydq2qkbjrx34cprzf0k6b93v7ch";
}) {} }:

pkgs.mkShell {
  name = "nim-waku-build-shell";

  # Versions dependent on nixpkgs commit. Update manually.
  buildInputs = with pkgs; [
    git   # 2.37.3
    which # 2.21
    rustc # 1.63.0
  ] ++ lib.optionals stdenv.isDarwin [ 
    libiconv
    darwin.apple_sdk.frameworks.Security
  ];

  LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
    pkgs.pcre
  ];
}
