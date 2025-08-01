#!/bin/bash

# Load env vars
source ./i13n-poc-configs/envvars.env

# Run nwaku
./build/wakunode2 \
  --config-file=./i13n-poc-configs/toml/bob.toml \
  --rln-relay-eth-client-address=$RLN_RELAY_ETH_CLIENT_ADDRESS \
  --rln-relay-cred-path=$RLN_RELAY_CRED_PATH \
  --rln-relay-cred-password=$RLN_RELAY_CRED_PASSWORD \
  --eligibility-eth-client-address=$ELIGIBILITY_ETH_CLIENT_ADDRESS
