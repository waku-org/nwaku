#!/usr/bin/env bash

# This script is used to build the rln library for the current platform, or download it from the
# release page if it is available.

set -e

# first argument is the build directory
build_dir=$1
rln_version=$2
output_filename=$3
target_arch=$4  # Optional: target architecture (e.g., amd64, arm64)

[[ -z "${build_dir}" ]]       && { echo "No build directory specified"; exit 1; }
[[ -z "${rln_version}" ]]     && { echo "No rln version specified";     exit 1; }
[[ -z "${output_filename}" ]] && { echo "No output filename specified"; exit 1; }

# Get the host triplet
host_triplet=$(rustc --version --verbose | awk '/host:/{print $2}')

# If target architecture is specified, map it to the appropriate rust target triplet
if [[ -n "${target_arch}" ]]; then
    detected_OS=$(uname -s)
    case "${detected_OS}" in
        Darwin)
            if [[ "${target_arch}" == "arm64" || "${target_arch}" == "aarch64" ]]; then
                host_triplet="aarch64-apple-darwin"
            elif [[ "${target_arch}" == "amd64" || "${target_arch}" == "x86_64" ]]; then
                host_triplet="x86_64-apple-darwin"
            fi
            ;;
        Linux)
            if [[ "${target_arch}" == "arm64" || "${target_arch}" == "aarch64" ]]; then
                host_triplet="aarch64-unknown-linux-gnu"
            elif [[ "${target_arch}" == "amd64" || "${target_arch}" == "x86_64" ]]; then
                host_triplet="x86_64-unknown-linux-gnu"
            fi
            ;;
    esac
    echo "Target architecture specified: ${target_arch}, using triplet: ${host_triplet}"
fi

tarball="${host_triplet}"

tarball+="-rln.tar.gz"

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
    # first, check if submodule version = version in Makefile
    cargo metadata --format-version=1 --no-deps --manifest-path "${build_dir}/rln/Cargo.toml"

    detected_OS=$(uname -s)
    if [[ "$detected_OS" == MINGW* || "$detected_OS" == MSYS* ]]; then
        submodule_version=$(cargo metadata --format-version=1 --no-deps --manifest-path "${build_dir}/rln/Cargo.toml" | sed -n 's/.*"name":"rln","version":"\([^"]*\)".*/\1/p')
    else
        submodule_version=$(cargo metadata --format-version=1 --no-deps --manifest-path "${build_dir}/rln/Cargo.toml" | jq -r '.packages[] | select(.name == "rln") | .version')
    fi

    if [[ "v${submodule_version}" != "${rln_version}" ]]; then
        echo "Submodule version (v${submodule_version}) does not match version in Makefile (${rln_version})"
        echo "Please update the submodule to ${rln_version}"
        exit 1
    fi
    # if submodule version = version in Makefile, build rln
    # Determine the target directory based on whether we're cross-compiling
    if [[ -n "${target_arch}" ]]; then
        # Extract the rust target from host_triplet (which was already adjusted above if target_arch was set)
        cargo build --release -p rln --manifest-path "${build_dir}/rln/Cargo.toml" --target "${host_triplet}"
        cp "${build_dir}/target/${host_triplet}/release/librln.a" "${output_filename}"
    else
        cargo build --release -p rln --manifest-path "${build_dir}/rln/Cargo.toml"
        cp "${build_dir}/target/release/librln.a" "${output_filename}"
    fi
fi
