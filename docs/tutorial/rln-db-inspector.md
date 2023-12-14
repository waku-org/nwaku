# rln-db-inspector

This document describes how to run and use the `rln-db-inspector` tool. 
It is meant to be used to debug and fetch the metadata stored in the RLN tree db.

## Pre-requisites

1. An existing RLN tree db

## Usage

1. First, we compile the binary
    
    ```bash
    make -j16 wakunode2
    ```
    This command will fetch the rln static library and link it automatically.


2. Define the arguments you wish to use

    ```bash
    export RLN_TREE_DB_PATH="xxx"
    ```

3. Run the db inspector 

    ```bash
    ./build/wakunode2 inspectRlnDb \
    --rln-relay-tree-path:$RLN_TREE_DB_PATH 
    ```

    What this does is - 
    a. loads the tree db from the path provided
    b. Logs out the metadata, including, number of leaves set, past 5 merkle roots, last synced block number

