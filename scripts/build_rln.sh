#!/usr/bin/env bash

# This script is used to build the rln library for the current platform, or download it from the
# release page if it is available.

set -e

# first argument is the build directory
build_dir=$1
rln_version=$2
output_filename=$3

if [[ -z "$build_dir" ]]; then
    echo "No build directory specified"
    exit 1
fi

if [[ -z "$rln_version" ]]; then
    echo "No rln version specified"
    exit 1
fi

if [[ -z "$output_filename" ]]; then
    echo "No output filename specified"
    exit 1
fi

# Get the host triplet
host_triplet=$(rustup show | grep "Default host: " | cut -d' ' -f3)

# Download the prebuilt rln library if it is available
if curl --silent --fail-with-body -L "https://github.com/vacp2p/zerokit/releases/download/$rln_version/$host_triplet-rln.tar.gz" >> "$host_triplet-rln.tar.gz"
then
    echo "Downloaded $host_triplet-rln.tar.gz"
    tar -xzf "$host_triplet-rln.tar.gz"
    mv release/librln.a $output_filename
    rm -rf "$host_triplet-rln.tar.gz" release
else
    echo "Failed to download $host_triplet-rln.tar.gz"
    # Build rln instead
    # first, check if submodule version = version in Makefile
    submodule_version=$(cargo metadata --format-version=1 --no-deps | jq '.packages[] | select(.name == "rln") | .version')
    if [[ "v$submodule_version" != "$rln_version" ]]; then
        echo "Submodule version (v$submodule_version) does not match version in Makefile ($rln_version)"
        echo "Please update the submodule to $rln_version"
        exit 1
    fi
    # if submodule version = version in Makefile, build rln
    cargo build --release -p rln --manifest-path "$build_dir/rln/Cargo.toml"
    cp "$build_dir/target/release/librln.a" $output_filename
fi
