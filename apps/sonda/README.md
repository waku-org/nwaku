# Sonda

Sonda is a tool to monitor store nodes and measure their performance.

It works by running a `nwaku` node, publishing a message from it every fixed interval and performing a store query to all the store nodes we want to monitor to check they respond with the last message we published.

## Instructions

1. Create an `.env` file which will contain the configuration parameters.
    You can start by copying `.env.example` and adapting it for your use case

    ```
    cp .env.example .env
    ${EDITOR} .env
    ```

    The variables that have to be filled for Sonda are

    ```
    CLUSTER_ID=
    SHARD=
    # Comma separated list of store nodes to poll
    STORE_NODES=
    # Wait time in seconds between two consecutive queries
    QUERY_DELAY=
    # Consecutive successful store requests to consider a store node healthy
    HEALTH_THRESHOLD=
    ```

2. If you want to query nodes in `cluster-id` 1, then you have to follow the steps of registering an RLN membership. Otherwise, you can skip this step.

    For it, you need:
    * Ethereum Sepolia WebSocket endpoint. Get one free from [Infura](https://www.infura.io/).
    * Ethereum Sepolia account with some balance <0.01 Eth. Get some [here](https://www.infura.io/faucet/sepolia).
    * A password to protect your rln membership.

    Fill the `RLN_RELAY_ETH_CLIENT_ADDRESS`, `ETH_TESTNET_KEY` and `RLN_RELAY_CRED_PASSWORD` env variables and run

    ```
    ./register_rln.sh
    ```

3. Start Sonda by running
   
    ```
    docker-compose up -d
    ```

4. Browse to http://localhost:3000/dashboards and monitor the performance

    There's two Grafana dashboards: `nwaku-monitoring` to track the stats of your node that is publishing messages and performing queries, and `sonda-monitoring` to monitor the responses of the store nodes.

