{
  config ? {},
  pkgs ? import <nixpkgs> { },
  src ? ../.,
  targets ? ["libwaku-android-arm64"],
  verbosity ? 2,
  useSystemNim ? true,
  quickAndDirty ? true,
  stableSystems ? [
    "x86_64-linux" "aarch64-linux"
  ],
  abidir ? null,
  zerokitRln,
}:

assert pkgs.lib.assertMsg ((src.submodules or true) == true)
  "Unable to build without submodules. Append '?submodules=1#' to the URI.";

let
  inherit (pkgs) stdenv lib writeScriptBin callPackage;

  revision = lib.substring 0 8 (src.rev or "dirty");

in stdenv.mkDerivation rec {

  pname = "nwaku";

  version = "1.0.0-${revision}";

  inherit src;

  buildInputs = with pkgs; [
    openssl
    gmp
    zip
  ];

  # Dependencies that should only exist in the build environment.
  nativeBuildInputs = let
    # Fix for Nim compiler calling 'git rev-parse' and 'lsb_release'.
    fakeGit = writeScriptBin "git" "echo ${version}";
    # Fix for the zerokit package that is built with cargo/rustup/cross.
    fakeCargo = writeScriptBin "cargo" "echo ${version}";
    # Fix for the zerokit package that is built with cargo/rustup/cross.
    fakeRustup = writeScriptBin "rustup" "echo ${version}";
    # Fix for the zerokit package that is built with cargo/rustup/cross.
    fakeCross = writeScriptBin "cross" "echo ${version}";
  in
    with pkgs; [
      cmake
      which
      lsb-release
      zerokitRln
      nim-unwrapped-2_0
      fakeGit
      fakeCargo
      fakeRustup
      fakeCross
  ];

  # Environment variables required for Android builds
  ANDROID_SDK_ROOT="${pkgs.androidPkgs.sdk}";
  ANDROID_NDK_HOME="${pkgs.androidPkgs.ndk}";
  NIMFLAGS = "-d:disableMarchNative -d:git_revision_override=${revision}";
  XDG_CACHE_HOME = "/tmp";
  androidManifest = "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\" package=\"com.example.mylibrary\" />";

  makeFlags = targets ++ [
    "V=${toString verbosity}"
    "QUICK_AND_DIRTY_COMPILER=${if quickAndDirty then "1" else "0"}"
    "QUICK_AND_DIRTY_NIMBLE=${if quickAndDirty then "1" else "0"}"
    "USE_SYSTEM_NIM=${if useSystemNim then "1" else "0"}"
  ];

  configurePhase = ''
    patchShebangs . vendor/nimbus-build-system > /dev/null
    make nimbus-build-system-paths
    make nimbus-build-system-nimble-dir
  '';

  preBuild = ''
    ln -s waku.nimble waku.nims
    pushd vendor/nimbus-build-system/vendor/Nim
    mkdir dist
    cp -r ${callPackage ./nimble.nix {}}    dist/nimble
    chmod 777 -R dist/nimble
    mkdir -p dist/nimble/dist
    cp -r ${callPackage ./checksums.nix {}} dist/checksums  # need both
    cp -r ${callPackage ./checksums.nix {}} dist/nimble/dist/checksums
    cp -r ${callPackage ./atlas.nix {}}     dist/atlas
    chmod 777 -R dist/atlas
    mkdir dist/atlas/dist
    cp -r ${callPackage ./sat.nix {}}       dist/nimble/dist/sat
    cp -r ${callPackage ./sat.nix {}}       dist/atlas/dist/sat
    cp -r ${callPackage ./csources.nix {}}  csources_v2
    chmod 777 -R dist/nimble csources_v2
    popd
    cp -r ${zerokitRln}/target vendor/zerokit/
    find vendor/zerokit/target
    # TODO
    #cp vendor/zerokit/target/release/librln.a librln_v0.7.0.a
  '';

  installPhase = if abidir != null then ''
    mkdir -p $out/jni
    cp -r ./build/android/${abidir}/* $out/jni/
    echo '${androidManifest}' > $out/jni/AndroidManifest.xml
    cd $out && zip -r libwaku.aar *
  '' else ''
    mkdir -p $out/bin
    cp -r build/* $out/bin
  '';

  meta = with pkgs.lib; {
    description = "NWaku derivation to build libwaku for mobile targets using Android NDK and Rust.";
    homepage = "https://github.com/status-im/nwaku";
    license = licenses.mit;
    platforms = stableSystems;
  };
}
