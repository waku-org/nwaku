{ 
  pkgs ? import <nixpkgs> { },
}:
let
  optionalDarwinDeps = pkgs.lib.optionals pkgs.stdenv.isDarwin [
    pkgs.libiconv
    pkgs.darwin.apple_sdk.frameworks.Security
  ];
in
pkgs.mkShell {
  inputsFrom = [
    pkgs.androidShell
  ] ++ optionalDarwinDeps;

  buildInputs = with pkgs; [
    git
    cargo
    rustup
    cmake
    nim-unwrapped-2_0
  ];

  LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
    pkgs.pcre
  ];
}
