#!/bin/bash

# Load env vars
source ./i13n-poc-configs/envvars.env

# Run nwaku
./build/wakunode2 \
  --config-file=./i13n-poc-configs/toml/alice.toml
