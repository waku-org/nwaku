#!/bin/bash

# Load env vars
source ./i13n-poc-configs/envvars.env

# Run nwaku
./build/wakunode2 \
  --config-file=./i13n-poc-configs/toml/dave.toml \
  --rln-relay-eth-client-address=$RLN_RELAY_ETH_CLIENT_ADDRESS 
