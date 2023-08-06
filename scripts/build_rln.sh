#!/usr/bin/env bash

# This script is used to build the rln library for the current platform, or download it from the
# release page if it is available.

set -e

# first argument is the build directory
build_dir=$1

if [[ -z "$build_dir" ]]; then
    echo "No build directory specified"
    exit 1
fi

# Get the host triplet
host_triplet=$(rustup show | grep "Default host: " | cut -d' ' -f3)

# Download the prebuilt rln library if it is available
if curl --silent --fail-with-body -L "https://github.com/vacp2p/zerokit/releases/download/v0.3.1/$host_triplet-rln.tar.gz" >> "$host_triplet-rln.tar.gz"
then
    echo "Downloaded $host_triplet-rln.tar.gz"
    tar -xzf "$host_triplet-rln.tar.gz"
    mv release/librln.a .
    rm -rf "$host_triplet-rln.tar.gz" release
else
    echo "Failed to download $host_triplet-rln.tar.gz"
    # Build rln instead
    cargo build --release -p rln --manifest-path "$build_dir/rln/Cargo.toml"
    cp "$build_dir/target/release/librln.a" .
fi
