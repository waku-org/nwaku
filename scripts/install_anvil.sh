#!/usr/bin/env bash

# Install Anvil

if ! command -v anvil &> /dev/null; then
    BASE_DIR="${XDG_CONFIG_HOME:-$HOME}"
    FOUNDRY_DIR="${FOUNDRY_DIR:-"$BASE_DIR/.foundry"}"
    FOUNDRY_BIN_DIR="$FOUNDRY_DIR/bin"

    curl -L https://foundry.paradigm.xyz | bash
    # Extract the source path from the download result
    echo "foundryup_path: $FOUNDRY_BIN_DIR"
    # run foundryup
    $FOUNDRY_BIN_DIR/foundryup
fi