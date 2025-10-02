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

  version = lib.substring 0 8 (src.sourceInfo.rev or "dirty");

in stdenv.mkDerivation rec {
  pname = "nwaku";
  inherit src version;

  buildInputs = with pkgs; [
    openssl
    gmp
    zip
    zerokitRln
  ];

  # Dependencies that should only exist in the build environment.
  nativeBuildInputs = let
    # Fix for Nim compiler calling 'git rev-parse' and 'lsb_release'.
    fakeGit = writeScriptBin "git" "echo ${version}";
  in
    with pkgs; [
      cmake
      which
      lsb-release
      nim-unwrapped-2_2
      fakeGit
  ];

  # Environment variables required for Android builds
  ANDROID_SDK_ROOT = "${pkgs.androidPkgs.sdk}";
  ANDROID_NDK_HOME = "${pkgs.androidPkgs.ndk}";
  NIMFLAGS = "--passL:'-L${zerokitRln}/lib' -d:disableMarchNative -d:git_revision_override=${version}";
  LIBRLN_FILE = "${zerokitRln}/lib/librln.a";
  XDG_CACHE_HOME = "/tmp";

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
    cp -r ${callPackage ./checksums.nix {}} dist/checksums
    cp -r ${callPackage ./csources.nix {}}  csources_v2
    chmod 777 -R dist/nimble csources_v2
    popd
  '';

  androidManifest = "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\" package=\"com.example.mylibrary\" />";

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
