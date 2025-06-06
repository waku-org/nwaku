#!/usr/bin/env bash

# Install pnpm
if ! command -v pnpm &> /dev/null; then
    echo "pnpm is not installed, installing it now..."
    curl -L https://unpkg.com/@pnpm/self-installer | node
fi

