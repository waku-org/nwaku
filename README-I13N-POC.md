
This document describes the testing for the service incentivization PoC for Waku Lightpush.

# Background

Waku provides a suite of light protocols that allow edge nodes to use network services without being full Relay nodes. In particular, the Lightpush protocol allows an edge node (client) to ask a service node to publish a message to the Waku network on its behalf. In order to publish a message to the Waku network, the service node must have an RLN membership. In other words, the Lightpush client asks the service node to spend some of its limited resources. The goal of this PoC is to demonstrate an incentivized setup between a Lightpush edge node and a service node. 

# Functionality overview

This proof-of-concept contains two additional modules: eligibility and reputation.

## Eligibility module

Eligibility allows a service node to determine whether an incoming Lightpush request is _eligible_ to be fulfilled. A request is considered eligible if it contains a _proof of payment_. In this PoC, a proof of payment is a transaction hash (txid) corresponding to a transaction on Linea Sepolia.

The PoC makes the following assumptions:
- the edge node learns off-band what the service node's on-chain address is (i.e., where payment must be made) and what amount is expected;
- the payment is made in native tokens (ETH), not in ERC-20 or other contract-based tokens;
- each request is paid for separately with its own transaction.

A Lightpush request is considered _eligible_ if and only if:
- there is a proof of payment (txid) attached to the request;
- the txid corresponds to a confirmed transaction on Linea Sepolia;
- the transaction transfers exactly the expected amount to the expected address;
- the transaction has not been used in previous requests.

## Reputation module

The reputation module allows edge nodes to avoid service nodes that provide poor service.

Reputation has three possible values: good, bad, and neutral. The goal of reputation is for the edge node to avoid service nodes that provide bad service. Initially, from the edge node's perspective, all peers have neutral reputation. If an edge node sends an eligible request that is not fulfilled, it marks the respective service node as having "bad reputation". Bad-reputation peers are not selected for future requests. After a successfully fulfilled request, the edge node changes the service node's reputation to "good".

Not all error responses lead to a decrease in the service node's reputation. If the request is rejected due to a missing or invalid proof of payment, the service node's reputation remains unchanged. The service node's reputation is decreased only if an _eligible_ request is not served.

 Reputation functionality only applies to peers selected from the peer store (i.e., connected to via `--staticnode`). There are two ways an edge node can choose a peer to send a Lightpush request to: select from the peer store, or use the peer from the service slot for Lightpush. If an edge node establishes a dedicated connection to a peer via `--lightpushnode`, that peer is put in the service slot for Lightpush. There can only be one peer in the service slot at any given time. If there is a peer in the service slot, all Lightpush requests go to that peer. In the testing scenarios described below, we deliberately avoid using `--lightpushnode` — otherwise, we wouldn't be able to test the reputation-based peer selection logic.

# Prerequisites

The testing setup (described below) consists of Edge Nodes and Service Nodes.
An Edge Node wants to send messages via Lightpush using a Service Node.
The Service Node uses its RLN membership to publish the Edge Node's message, if the request is eligible.

There are two tokens involved (both on Linea Sepolia):
- TTT: custom ERC-20 tokens on Linea Sepolia required to register an RLN membership;
- Linea Sepolia ETH: native tokens that the edge node uses to pay the service node.

Payment and service relationships are shown on this diagram:

```mermaid
graph LR
    A["Edge Node"] -- "3\. Pay in ETH" --> B["Service Node"]
    B -- "1\. Deposit TTT" --> C[RLN contract]
    C -- "2\. RLN membership" --> B
    B -- "4\. RLN-as-a-service" --> A
```

You have the following options:
1. reproduce the testing scenario as is, using existing confirmed proof-of-payment transactions;
2. send your own transactions.

Use the following flowchart and table to determine prerequisites for your testing scenario.

| Goal                                                                   | Required Components                                    | Optional / Conditional Steps                                                                                       |
| ---------------------------------------------------------------------- | ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------ |
| **Reproduce the scenario with existing transactions**                  | • Linea Sepolia RPC endpoint<br>• RLN membership       | If you **don’t** have RLN membership:<br>• Get Linea Sepolia ETH<br>• Mint TTT tokens<br>• Register RLN membership |
| **Reproduce the scenario with your own proof-of-payment transactions** | All of the above + Linea Sepolia ETH (for sending txs) | Get Linea Sepolia ETH:<br>• From faucet **or**<br>• By bridging from Ethereum Sepolia                              |


```mermaid
graph TD

A[Start] --> B[Get a Linea Sepolia RPC endpoint]
B --> C{Have RLN membership on **Linea Sepolia**?}

C -- Yes --> D[Ready to test with existing transactions]
C -- No --> E[Get Linea Sepolia ETH from Faucet or Bridge]
E --> F[Register RLN membership]
F --> D

D --> H{Want to send own transactions?}
H -- No --> I[Done]
H -- Yes --> J[Ensure you have Linea Sepolia ETH]

```


The next sub-sections describe each prerequisite in more detail.

## Get a Linea Sepolia RPC endpoint

See this [list of node providers](https://docs.linea.build/get-started/tooling/node-providers) on the official Linea website.

An Linea Sepolia RPC endpoint serves two purposes:
- create an RLN membership and generate proofs (as before);
- check eligibility proofs (functionality added in this PoC).

For extensibility, these two purposes are represented by different configuration parameters in the PoC.
You may use the same or different RPC endpoints as values for these parameters.

## Get Linea Sepolia ETH

There are multiple ways to get Linea Sepolia ETH:
1. Get Linea Sepolia ETH directly from a faucet (see [list of faucets](https://docs.linea.build/get-started/how-to/get-testnet-eth)); or
2. Swap Ethereum Sepolia ETH to Linea Sepolia ETH (see [native bridge](https://linea.build/hub/bridge/native-bridge) - be sure to select "Show Test Networks" in settings); or
3. Ask friends or colleagues if they can give you some Linea Sepolia ETH (or Ethereum Sepolia ETH - then bridge them to Linea Sepolia as described above).

## Register RLN membership (and mint TTT tokens)

In order to publish a message, a valid RLN membership is needed.
The easiest way to proceed it to use `register_rln.sh` script from [`nwaku-compose`](https://github.com/waku-org/nwaku-compose).
The `register_rln.sh` script from `nwaku-compose` mints TTT tokens (necessary for RLN deposit) _and_ registers an RLN membership in one go.
If you use `register_rln.sh`, you do not need to take separate action to mint TTT.

> [!note]
> You will clone `nwaku-compose` repository in addition to `nwaku` repository. This setup **only** uses `nwaku-compose` for its RLN registration script. We do **not** proceed with running `nwaku` via `docker compose`, which in `nwaku-compose`'s main purpose. Instead, after registering the RLN membership, we run `nwaku` directly from a binary built from source.

Follow these steps to register an RLN membership.

We suggest the following directory structure (we will need both `nwaku` and `nwaku-compose` repositories):
```
- nwaku-poc-testing
	- nwaku-compose
	- nwaku
```

Clone `nwaku-compose`:
```
git clone git@github.com:waku-org/nwaku-compose.git
cd nwaku-compose
```

Copy an example template of the environment file and open it for editing:
```
cp .env.example .env
nano .env
```

> [!note]
> You can use another text editor instead of `nano` if you prefer.

Set the necessary parameters in the `.env` file:

| Parameter                      | Comment                                                                             |
| ------------------------------ | ----------------------------------------------------------------------------------- |
| `RLN_RELAY_ETH_CLIENT_ADDRESS` | Linea Sepolia RPC URL endpoint (without quotes).                                    |
| `ETH_TESTNET_ACCOUNT`          | Linea Sepolia account for which RLN membership will be registered (without quotes). |
| `ETH_TESTNET_KEY`              | The private key for `ETH_TESTNET_ACCOUNT` **without** `0x` prefix (without quotes). |
| `RLN_RELAY_CRED_PASSWORD`      | A password to protect your RLN membership (in double-quotes).                       |

> [!note]
> `ETH_TESTNET_KEY` must be the private key of `ETH_TESTNET_ACCOUNT`.

> [!hint]
> Here is how to [export your private key](https://support.metamask.io/configure/accounts/how-to-export-an-accounts-private-key/) from Metamask.

> [!warning]
> Do not change any other values in `.env` unless you really know what you are doing.

Run the RLN registration script. This script will register an RLN membership and store its keys in the keystore:
```
./register_rln.sh
```

If registration is successful, you will see a message like this:
```
INF 2025-07-25 10:11:32.243+00:00 credentials persisted                      topics="rln_keystore_generator" tid=1 file=rln_keystore_generator.nim:119 path=/keystore/keystore.json
```

Change the ownership of the keystore so that it is later available from `nwaku` directory:
```
sudo chown -R $USER:$USER keystore
```

You will then use that keystore to proceed with the testing scenario.

> [!note]
> After this point, we will now use `nwaku-compose` anymore. All future steps assume using the `wakunode2` binary built from source.

Return to the outer directory:
```
cd ../
```

# Build `nwaku` from source

To use the PoC, you need to build `wakunode2` from source on the corresponding feature branch.

Clone the repo and check out the [`feat/service-incentivization-poc`](https://github.com/waku-org/nwaku/tree/feat/service-incentivization-poc) feature branch: 

```
git clone git@github.com:waku-org/nwaku.git
cd nwaku
git checkout feat/service-incentivization-poc
```

Build `wakunode2` from source (see also: [instructions on building from source](https://docs.waku.org/guides/nwaku/build-source)):

```
make update
make wakunode2
```

> [!note]
> To speed up building, you may specify `-j` parameter to use multiple cores in parallel (depends on your CPU). For example, `make -j20 wakunode` will use 20 cores.

Verify that the binary is built:
```
./build/wakunode2 --version
```

Expected output (exact values may be different; we just check that the binary is there):
```
version / git commit hash: v0.35.1-167-g248757
[Summary] 0 tests run (0.00s): 0 OK, 0 FAILED, 0 SKIPPED
```

# Experimental setup overview

This section describes a local setup containing multiple `nwaku` nodes used to test the PoC.

The setup contains four nodes.
Nodes are launched on the same machine on different ports.
Note that REST API commands must use the appropriate port corresponding to the node queried.
Nodes are defined by a set of parameters defined as CLI arguments or in a TOML config file.
Config files for the four nodes are in the directory `./i13n-poc-configs/toml`'.
CLI arguments override config parameters.

Our setup includes the following nodes:
- Alice — the edge node that wants to publish messages without being connected to Relay.
- Bob — the service node that fulfills Alice's request.
- Charlie — the alternative service node that fails to fulfill Alice's request.
- Dave — the node that Bob connects to via Relay to publish Alice's message.

```mermaid
graph LR
  Alice -- Lightpush --> Bob
  Bob <-- Relay --> Dave
  Alice -- Lightpush --> Charlie
  Dave <-- Relay --> W((The Waku Network))
```

For reproducibility, nodes are launched with the same (static) keys defined in config files.
Example commands use the pre-generated constant keys from which node IDs are derived.
Instructions for key config can be found [here](https://github.com/waku-org/nwaku/blob/master/docs/operators/how-to/configure-key.md).


> [!note]
> In the testing scenario, Bob and Charlie share on-chain credentials and therefore can be considered one entity from the payment perspective.

> [!note] 
> Nodes do not save eligibility and reputation data between restarts.

# Reproduce the testing scenario

## Set environment variables

Make a file called `wakunode2.env` in your project root (or home directory):

```
nano ./i13n-poc-configs/envvars.env
```

In the environment file, set the necessary environment variables (replace `API_KEY` with your Infura API key, or replace the whole URL if you use another RPC provider):
```
export ELIGIBILITY_ETH_CLIENT_ADDRESS="https://linea-sepolia.infura.io/v3/API_KEY"
export RLN_RELAY_ETH_CLIENT_ADDRESS="https://linea-sepolia.infura.io/v3/API_KEY"
export RLN_RELAY_CRED_PATH="../nwaku-compose/keystore/keystore.json"
export RLN_RELAY_CRED_PASSWORD="12345678"
```

> [!warning]
> If you have moved the keystore from `nwaku-compose`, change `RLN_RELAY_CRED_PATH` accordingly.

> [!note]
> You may use the same RPC endpoint as `ELIGIBILITY_ETH_CLIENT_ADDRESS` and `RLN_RELAY_ETH_CLIENT_ADDRESS`.

> [!note]
> All RLN-enabled nodes in the setup (namely, Bob and Charlie) use the same RLN membership (i.e., the same keystore).

## Launch nodes

Make node-launching scripts executable:

```
chmod +x ./i13n-poc-configs/*.sh
```

Launch nodes in different terminal windows (**in this order** - important for proper connection establishment):

```
./i13n-poc-configs/run_charlie.sh
```

```
./i13n-poc-configs/run_alice.sh
```

```
./i13n-poc-configs/run_dave.sh
```

```
./i13n-poc-configs/run_bob.sh
```


## Run the testing scenario

To communicate with Waku nodes, use REST API interface (see [REST API reference](https://waku-org.github.io/waku-rest-api/)).

## Alice is only connected to Charlie

Initially, Alice is only connected to Charlie. We test negative scenarios when Alice's requests cannot be fulfilled. We will connect Alice to Bob later in the scenario.

### Alice sends ineligible requests, Charlie denies

Alice sends a series of ineligible requests (without proof of payment and with invalid proof of payment).
1. Charlie is selected as service node (it is the only peer with neutral reputation Alice is aware of).
2. All ineligible requests are rejected, Alice receives error messages, Charlie's reputation remains unchanged.

> [!note]
> In all experiments, we explicitly use pubsub topic `waku/2/rs/1/0` i.e. shard `0` on The Waku Network. `%2Fwaku%2F2%2Frs%2F1%2F0` is an encoding of `/waku/2/rs/1/0` - the pubsub topic (i.e. identifier) of shard `0`.

REST API request from Alice without proof of payment:
```
curl -X POST "http://127.0.0.1:8646/lightpush/v3/message" -H "accept: application/json" -H "Content-Type: application/json" -d '{ "pubsubTopic": "/waku/2/rs/1/0", "message": { "payload": "SGVsbG8gV29ybGQ=", "contentTopic": "/i13n-poc/1/chat/proto" } }'
```

Expected response:
```
{"statusDesc":"Eligibility proof is required"}
```

REST API request from Alice with a non-existent transaction as proof of payment:
```
curl -X POST "http://127.0.0.1:8646/lightpush/v3/message" -H "accept: application/json" -H "Content-Type: application/json" -d '{ "pubsubTopic": "/waku/2/rs/1/0", "message": { "payload": "SGVsbG8gV29ybGQ=", "contentTopic": "/i13n-poc/1/chat/proto" }, "eligibilityProof": "0x0000000000000000000000000000000000000000000000000000000000000000" }'
```

Expected response:
```
{"statusDesc":"Eligibility check failed: Failed to fetch tx or tx receipt"}
```

REST API request form Alice with a transaction with incorrect amount (higher than expected):
```
curl -X POST "http://127.0.0.1:8646/lightpush/v3/message" -H "accept: application/json" -H "Content-Type: application/json" -d '{ "pubsubTopic": "/waku/2/rs/1/0", "message": { "payload": "SGVsbG8gV29ybGQ=", "contentTopic": "/i13n-poc/1/chat/proto" }, "eligibilityProof": "0x0a502f0a367f99b50e520afeb3843ee9e0f73fd0f01d671829c0c476d86859df" }'
```

Expected response:
```
{"statusDesc":"Eligibility check failed: Wrong tx value: got 2000000000, expected 1000000000"}
```

>[!note]
>The amount must be exactly as expected, counted in wei. In the PoC currently, exceeding amounts are also rejected.

REST API request from Alice with a transaction with incorrect amount (lower than expected):

```
curl -X POST "http://127.0.0.1:8646/lightpush/v3/message" -H "accept: application/json" -H "Content-Type: application/json" -d '{ "pubsubTopic": "/waku/2/rs/1/0", "message": { "payload": "SGVsbG8gV29ybGQ=", "contentTopic": "/i13n-poc/1/chat/proto" }, "eligibilityProof": "0xa3c5da96b234518ae544c3449344cf4216587f400a529a836ce6131a82228363" }'
```

Expected response:
```
{"statusDesc":"Eligibility check failed: Wrong tx value: got 900000000, expected 1000000000"}
```

> [!note]
> All failed responses mentioned above must not affect Charlie's reputation from Alice's point of view, which is reflected in Alice's log with lines like: `DBG 2025-07-10 16:30:46.623+02:00 Neutral response - reputation unchanged for peer tid=25598 file=reputation_manager.nim:63 peer=16U*EuyzSd`.

### Alice sends an eligible request, Charlie fails to fulfill it

Alice sends an eligible request.
1. Charlie is again selected as service node.
2. Charlie fails to fulfill the request due to being isolated.
3. Alice receives an error message and sets Charlie's reputation to "bad".

REST API request from Alice with a valid proof of payment:
```
curl -X POST "http://127.0.0.1:8646/lightpush/v3/message" -H "accept: application/json" -H "Content-Type: application/json" -d '{ "pubsubTopic": "/waku/2/rs/1/0", "message": { "payload": "SGVsbG8gV29ybGQ=", "contentTopic": "/i13n-poc/1/chat/proto" }, "eligibilityProof": "0x67932980dd5e66be76d4d096f3e176b2f1590cef3aa9981decb8f59a5c7e60e3" }'
```

Expected response:
```
{"statusDesc":"No peers for topic, skipping publish"}
```

Alice assigns bad reputation to Charlie because a valid request was not served (check Alice's logs for lines like this):
```
DBG 2025-07-10 16:33:00.897+02:00 Assign bad reputation for peer       tid=25598 file=reputation_manager.nim:57 peer=16U*EuyzSd
```

## Alice is connected to Bob and Charlie

Now, let us additionally connect Alice to Bob.

Connect Alice to Bob (via REST API, without re-launching)

```
curl -X POST "http://127.0.0.1:8646/admin/v1/peers" -H "accept: text/plain" -H "content-type: application/json" -d '["/ip4/127.0.0.1/tcp/60000/p2p/16Uiu2HAmVHRbXuE4MUZbZ4xXF5CnVT5ntNGS3z7ER1fX1aLjxE95"]'
```

Verify that Alice is connected to Bob:

```
curl -X GET "http://127.0.0.1:8646/admin/v1/peers/connected" | jq . | grep multiaddr
```

Expected response (both Bob's and Charlie's node IDs must appear here; a real IP address replaced with `EXTERNAL_IP`):
```
  "multiaddr": "/ip4/EXTERNAL_IP/tcp/60000/p2p/16Uiu2HAmVHRbXuE4MUZbZ4xXF5CnVT5ntNGS3z7ER1fX1aLjxE95",
  "multiaddr": "/ip4/EXTERNAL_IP/tcp/60003/p2p/16Uiu2HAkyxHKziUQghTarGhBSFn8GcVapDgkJjMFTUVCCfEuyzSd",
```

### Alice sends an eligible request, Bob fulfills it

Alice sends an eligible request. Expected behavior:
1. Bob is selected (even though Alice is also aware of Charlie, Charlie is excluded due to its bad reputation).
2. Bob serves the request and returns a success message to Alice.
3. Alice sets Bob's reputation to "good".

```
curl -X POST "http://127.0.0.1:8646/lightpush/v3/message" -H "accept: application/json" -H "Content-Type: application/json" -d '{ "pubsubTopic": "/waku/2/rs/1/0", "message": { "payload": "SGVsbG8gV29ybGQ=", "contentTopic": "/i13n-poc/1/chat/proto" }, "eligibilityProof": "0x67932980dd5e66be76d4d096f3e176b2f1590cef3aa9981decb8f59a5c7e60e3" }'
```

Expected response (indicates successful publishing of the message):
```
{"relayPeerCount":1}
```

> [!note]
> If you get `no suitable peers and no discovery method` here instead, it's likely that Bob already has a bad reputation with Alice due to an earlier failed request.

> [!note]
> It is sufficient for Alice's message to be propagated to just one node (in this scenario, from Bob to Dave) for the request to be considered successfully fulfilled. The testing scenario does not require Bob or Dave to be additionally connected to The Waku Network.

Alice's log must also contain lines like the following. This shows that even though Alice is aware of two potential peers to select for her request, due to reputation system, only one peer (Bob) is considered. Moreover, Bob initially has a neutral (`none(bool)`) reputation because Alice hasn't had any interaction with Bob yet:
```
DBG 2025-07-10 16:42:24.575+02:00 Before filtering - total peers:      topics="waku node peer_manager" tid=25598 file=peer_manager.nim:253 numPeers=2
DBG 2025-07-10 16:42:24.576+02:00 Reputation enabled: consider only non-negative reputation peers topics="waku node peer_manager" tid=25598 file=peer_manager.nim:256
DBG 2025-07-10 16:42:24.576+02:00 Pre-selected peers from peerstore:     topics="waku node peer_manager" tid=25598 file=peer_manager.nim:272 numPeers=1
DBG 2025-07-10 16:42:24.576+02:00 Selected peer has reputation        topics="waku node peer_manager" tid=25598 file=peer_manager.nim:280 reputation=none(bool)
```

Upon successful request handling, a line like this must appear in Alice's log, which shows that Alice has assigned a good reputation to Bob following his successful handling of her request:
```
DBG 2025-07-10 16:42:25.457+02:00 Assign good reputation for peer      tid=25598 file=reputation_manager.nim:60 peer=16U*LjxE95
```

Verify, on Dave's node, that Alice's message has indeed reached Dave.

Get latest messages on shard `0`:
```
curl -X GET "http://127.0.0.1:8647/relay/v1/messages/%2Fwaku%2F2%2Frs%2F1%2F0"
```

Expected response (truncated; `i13n-poc` is short for "incentivization proof-of-concept"):
```
[{"payload":"SGVsbG8gV29ybGQ=","contentTopic":"/i13n-poc/1/chat/proto","version":0,"timestamp":1752158544577207808,"ephemeral":false, ....
```

### Alice attempts to double-spend, Bob denies

Alice sends an ineligible request with a double-spend attempt (trying to reuse a txid twice).
1. Bob is again selected as service peer.
2. Bob rejects the request and returns a corresponding error message.
3. Alice doesn't change Bob's reputation.

REST API request (same as the first eligible request, with the same txid):
```
curl -X POST "http://127.0.0.1:8646/lightpush/v3/message" -H "accept: application/json" -H "Content-Type: application/json" -d '{ "pubsubTopic": "/waku/2/rs/1/0", "message": { "payload": "SGVsbG8gV29ybGQ=", "contentTopic": "/i13n-poc/1/chat/proto" }, "eligibilityProof": "0x67932980dd5e66be76d4d096f3e176b2f1590cef3aa9981decb8f59a5c7e60e3" }'
```

Expected response:
```
{"statusDesc":"Eligibility check failed: TxHash 0x67932980dd5e66be76d4d096f3e176b2f1590cef3aa9981decb8f59a5c7e60e3 was already checked (double-spend attempt)"}
```

End of testing scenario.

# Appendix

## Eligibility parameters and txids

Transactions have been confirmed on Linea Sepolia for testing purposes.

Transaction IDs with correct amount (should succeed if the service node is connected to at least one other node):

```
0x67932980dd5e66be76d4d096f3e176b2f1590cef3aa9981decb8f59a5c7e60e3
0x7dff359c2eda52945f278341d056049510110030ac9545448762b70490eb6260
0x3c93f0e5f18667dce2dd99253152253a05bc42ff48140c21107c5d6a891d1a29
0xb5b7230a2eacfb70238843feb26ace80f01500376eb7b976f4757b0f1429e5d0
0x4bdfdc1019a6e8a0d098e59592f076d50b54d7a7e18f86a0f758eb8c6e9e96b7
```

Transaction IDs to the expected address with wrong amount (must fail regardless of the service node's connection status and return the appropriate error):

```
0x0a502f0a367f99b50e520afeb3843ee9e0f73fd0f01d671829c0c476d86859df
0x0a502f0a367f99b50e520afeb3843ee9e0f73fd0f01d671829c0c476d86859df
```

Transaction ID to the wrong address with the correct amount (must fail):
```
0x8a7548b4552dea4e6ef1a3d7b13a0ab9759b5be0ce3f6599d28d04c3aaa1fa1e
```

Transaction ID that doesn't correspond to a confirmed transaction (must fail):
```
0x0000000000000000000000000000000000000000000000000000000000000000
```

## Node keys and node IDs

The following table contains, for the reference, node (private) keys and node IDs of all nodes of the testing setup.

> [!warning]
> The following table is valid as of 2025-07-18. Setup may have changed. See config files for up-to-date values.

|Name|Protocols enabled|Node key|Node ID|Ports shift|TCP port|REST API port|
|---|---|---|---|---|---|---|
|Alice|Lightpush (client)|`17950ef7510db19197ec0e3d34b41c0ed60bb7a0a619aa504eb6689c85ca9925`|`16Uiu2HAkwxC5Mcsh2DyZBq8CiKqnDkLUHWTuXCJas3TMPmRkynWz`|1|60001|8646|
|Bob|Relay, Lightpush (server)|`2bd3bbef1afa198fc614a254367de5ae285d799d7b1ba6d9d8543ba41038bbed`|`16Uiu2HAmVHRbXuE4MUZbZ4xXF5CnVT5ntNGS3z7ER1fX1aLjxE95`|0|60000|8645|
|Charlie|Relay|`fbfa8c3e38e7594500e9718b8c800e2d1a3ef5bc65ce041adf788d276035230f`|`16Uiu2HAkyxHKziUQghTarGhBSFn8GcVapDgkJjMFTUVCCfEuyzSd`|3|60003|8648|
|Dave|Relay|`166aee32c415fe796378ca0336671f4ec1fa26648857a86a237e509aaaeb1980`|`16Uiu2HAmSCUwvwDnXm7PyVbtKiQ5xzXb36wNw8YbGQxcBuxWTuU8`|2|60002|8647|
