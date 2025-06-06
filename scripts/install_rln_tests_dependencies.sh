#!/usr/bin/env bash

# Install Anvil
if ! command -v anvil &> /dev/null; then
    ./scripts/install_anvil.sh
fi

#Install pnpm
if ! command -v pnpm &> /dev/null; then
    ./scripts/install_pnpm.sh
fi