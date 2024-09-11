#!/usr/bin/env bash

# This script is used to build the rln library for the current platform, or download it from the
# release page if it is available.

set -e

# first argument is the build directory
build_dir=$1
rln_version=$2
output_filename=$3

[[ -z "${build_dir}" ]]       && { echo "No build directory specified"; exit 1; }
[[ -z "${rln_version}" ]]     && { echo "No rln version specified";     exit 1; }
[[ -z "${output_filename}" ]] && { echo "No output filename specified"; exit 1; }

# Detect OS
case "$(uname -s)" in
    Linux*)     os=linux;;
    Darwin*)    os=darwin;;
    MINGW*)     os=windows;;
    MSYS*)      os=windows;;
    *)          os=unknown;;
esac

# Get the host triplet
if [ "$os" = "windows" ]; then
    host_triplet=$(rustc -vV | sed -n 's/host: //p')
else
    host_triplet=$(rustc --version --verbose | awk '/host:/{print $2}')
fi

tarball="${host_triplet}"

# use arkzkey feature for v0.5.1
# TODO: update this script in the future when arkzkey is default
if [[ "${rln_version}" == "v0.5.1" ]]; then
    tarball+="-arkzkey-rln.tar.gz"
else
    tarball+="-rln.tar.gz"
fi

# Download the prebuilt rln library if it is available
if curl --silent --fail-with-body -L \
  "https://github.com/vacp2p/zerokit/releases/download/$rln_version/$tarball" \
  -o "${tarball}";
then
    echo "Downloaded ${tarball}"
    tar -xzf "${tarball}"
    mv "release/librln.a" "${output_filename}"
    rm -rf "${tarball}" release
else
    echo "Failed to download ${tarball}"
    # Build rln instead
    cargo_metadata=$(cargo metadata --format-version=1 --no-deps --manifest-path "${build_dir}/rln/Cargo.toml")
    
    if [ "$os" = "windows" ]; then
        submodule_version=$(echo "$cargo_metadata" | sed -n 's/.*"name":"rln","version":"\([^"]*\)".*/\1/p')
    else
        submodule_version=$(echo "$cargo_metadata" | jq -r '.packages[] | select(.name == "rln") | .version')
    fi
    
    if [[ "v${submodule_version}" != "${rln_version}" ]]; then
        echo "Submodule version (v${submodule_version}) does not match version in Makefile (${rln_version})"
        echo "Please update the submodule to ${rln_version}"
        exit 1
    fi
    # if submodule version = version in Makefile, build rln
    cargo build --release -p rln --manifest-path "${build_dir}/rln/Cargo.toml" --features arkzkey
    cp "${build_dir}/target/release/librln.a" "${output_filename}"
fi
