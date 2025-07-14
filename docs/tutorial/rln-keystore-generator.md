# rln-keystore-generator

This document describes how to run and use the `rln-keystore-generator` tool. 
It is meant to be used to generate and persist a set of valid RLN credentials to be used with rln-relay.

## Pre-requisites

1. An EOA with some ETH to pay for the registration transaction ($PRIVATE_KEY)
2. An RPC endpoint to connect to an Ethereum node ($RPC_URL)

## Usage

1. First, we compile the binary
    
    ```bash
    make -j16 wakunode2
    ```
    This command will fetch the rln static library and link it automatically.


2. Define the arguments you wish to use

    ```bash
    export RPC_URL="https://sepolia.infura.io/v3/..."
    export PRIVATE_KEY="0x..."
    export RLN_CONTRACT_ADDRESS="0xB9cd878C90E49F797B4431fBF4fb333108CB90e6"
    export RLN_CREDENTIAL_PATH="rlnKeystore.json"
    export RLN_CREDENTIAL_PASSWORD="xxx"
    ```

3. Dry run the command to ensure better degree of execution 

    ```bash
    ./build/wakunode2 generateRlnKeystore \
    --rln-relay-eth-client-address:$RPC_URL \
    --rln-relay-eth-private-key:$PRIVATE_KEY \
    --rln-relay-eth-contract-address:$RLN_CONTRACT_ADDRESS \
    --rln-relay-cred-path:$RLN_CREDENTIAL_PATH \
    --rln-relay-cred-password:$RLN_CREDENTIAL_PASSWORD 
    ```
    By default, the tool will not execute a transaction. It will execute only if `--execute` is passed in.

4. Run the keystore generator with the onchain registration

    ```bash
    ./build/wakunode2 generateRlnKeystore \
    --rln-relay-eth-client-address:$RPC_URL \
    --rln-relay-eth-private-key:$PRIVATE_KEY \
    --rln-relay-eth-contract-address:$RLN_CONTRACT_ADDRESS \
    --rln-relay-cred-path:$RLN_CREDENTIAL_PATH \
    --rln-relay-cred-password:$RLN_CREDENTIAL_PASSWORD \
    --execute
    ```

    What this does is - 
    a. generate a set of valid rln credentials
    b. registers it to the contract address provided
    c. persists the credentials to the path provided

5. You may now use this keystore with wakunode2 or chat2.

## Troubleshooting

1. `KeystoreCredentialNotFoundError`

    ```
    KeystoreCredentialNotFoundError: Credential not found in keystore
    ```
    This is most likely due to multiple credentials present in the same keystore. 
    To navigate around this, both chat2 and wakunode2 have provided an option to specify the credential index to use (`--rln-relay-membership-index`).
    Please use this option with the appropriate tree index of the credential you wish to use.
        

