#!/usr/bin/env bash

nwaku_build_dir=$1
zerokit_dir=$2
rln_version=$3

[[ -z "${nwaku_build_dir}" ]]       && { echo "No nwaku build directory specified"; exit 1; }
[[ -z "${zerokit_dir}" ]]       && { echo "No zerokit directory specified"; exit 1; }
[[ -z "${rln_version}" ]]     && { echo "No rln version specified";     exit 1; }

export RUSTFLAGS="-Ccodegen-units=1"

cargo install cross --git https://github.com/cross-rs/cross

declare -A architectures
architectures["x86_64-linux-android"]="x86_64"
architectures["aarch64-linux-android"]="arm64-v8a"
architectures["i686-linux-android"]="x86"
architectures["armv7-linux-androideabi"]="armeabi-v7a"

for arch in "${!architectures[@]}"; do
  abi=`echo "${architectures[$arch]}"`
  output_dir=`echo ${nwaku_build_dir}/android/${abi}`
  mkdir -p ${output_dir}
  pushd ${zerokit_dir}/rln
  cargo clean
  cross rustc --release --lib --target=${arch} --crate-type=cdylib
  cp ../target/${arch}/release/librln.so ${output_dir}/.
  popd
done
