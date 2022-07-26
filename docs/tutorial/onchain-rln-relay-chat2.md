#  Spam-protected chat2 application with on-chain group management

This document is a tutorial on how to run the chat2 application over a spam-protected content topic i.e., `/toy-chat/2/luzhou/proto` using the WAKU-RLN-Relay protocol in the on-chain mode.
Unlike prior released tutorials, the group management in the on-chain mode is dynamic and is moderated via a membership smart contract that is deployed on the Ethereum testnet of Goerli.
The on-chain group management gives the benefit of dynamic group size where the size can grow up to 2^20 members.


## Prerequisites 
In this tutorial, you will need 1) an Ethereum account with at least `0.001` ethers on the Goerli testnet and 2) a hosted node on the Goerli testnet. 
In case you are not familiar with either of these two steps, you may use the following tutorial on the [prerequisites of running on-chain spam-protected chat2](./pre-requisites-of-running-on-chain-spam-protected-chat2.md).
Note that the required `0.001` ethers correspond to the registration fee, 
however, you still need to have more funds in your account to cover the cost of the transaction gas fee.



## Overview
At a high level,  when a chat2 client is spun up with waku-rln-relay mounted in on-chain mode, it creates rln credentials i.e., an identity key and an identity commitment key and 
registers them to the membership contract by sending a transaction.
This transaction will consume some funds from the supplied Ethereum Goerli account. 
Once the transaction is mined and the registration is successful, the registered credentials will get displayed on the console.
Under the hood, the chat2 client constantly listens to the membership contract and keeps itself updated with the latest state of the group.
Note that you may copy the displayed rln credentials and reuse them for the future execution of chat2.
If you choose not to reuse the same credentials, then for each execution, a new registration takes place and more funds get deducted from your Ethereum account.

In this test,  you will connect your chat2 client to the waku test fleets as the first hop. 
Test fleets are already running waku-rln-relay over the same pubsub topic and content topic as your chat2 client i.e., default pubsub topic `/waku/2/default-waku/proto` and the content topic of `/toy-chat/2/luzhou/proto`. 
As such, test fleets will filter spam messages published on this specific combination of topics, and do not route them.

## Build chat2
First, build chat2 with the RLN flag set to true.

```
make chat2 RLN=true
```

## Set up a chat2 client

Run the following command to set up your chat2 client. 

```
./build/chat2  --fleet:test --content-topic:/toy-chat/2/luzhou/proto --rln-relay:true --rln-relay-dynamic:true --eth-mem-contract-address:0x4252105670fE33D2947e8EaD304969849E64f2a6  --eth-account-address:your_eth_account --eth-account-privatekey:your_eth_private_key  --eth-client-address:your_goerli_node  --ports-shift=1  

```

In this command
- the `--fleet`:`test` indicates that the chat2 app gets connected to the test fleets.
- the `--content-topic`:`/toy-chat/2/luzhou/proto` indicates the content topic the chat2 application is being run.
- the `rln-relay` flag is set to true to enable RLN-Relay protocol for spam protection.
- the `--rln-relay-dynamic` flag is set to run the rln-relay protocol in on-chain mode with dynamic group management.
- the `--eth-mem-contract-address` command option gets the address of the membership contract.
  The current address of the contract is `0x4252105670fE33D2947e8EaD304969849E64f2a6`.
  You may check the state of the contract on [Goerli testnet](https://goerli.etherscan.io/address/0x5DE1Fb10345Ef1647629Df30e6C397297Da09A1d).
- the `eth-account-address` option is for your account address on Goerli testnet.
  You need to replace `your_eth_account` with your actual account address.
  It is a  hex string of size 40 (not sensitive to the `0x` prefix). 
- the `eth-account-privatekey` option is for your account private key on Goerli testnet. 
  You need to replace `your_eth_private_key` with the private key of your account on the Goerli testnet. 
  It is made up of 64 hex characters (not sensitive to the `0x` prefix).
- the `eth-client-address` should be assigned with the address of the hosted node on the Goerli testnet. 
  You need to replace the `your_goerli_node` with the actual node's address.

You may set up more than one chat client,
just make sure that you increment the `--ports-shift` value for each new client you set up e.g., `--ports-shift=2`.

<!-- You can pass your index using this command `--rln-relay-membership-index: your_index` e.g., `--rln-relay-membership-index:19` .
Please use the index assigned to you in the dogfooding coordination phase.
If you pick an index at random you may end up using the same key pair as someone else, hence your messaging rate will be shared with that person(s).
 -->

Next, choose your nickname:
```
Choose a nickname >> your_nick_name
```

then you will see a couple of other messages related to setting up the connections of your chat app,
the content may differ on your screen though:
```
Connecting to test fleet using DNS discovery...
Discovered and connecting to @[16Uiu2HAkvWiyFsgRhuJEb9JfjYxEkoHLgnUQmr1N5mKWnYjxYRVm, 16Uiu2HAmPLe7Mzm8TsYUubgCAW1aJoeFScxrLj8ppHFivPo97bUZ, 16Uiu2HAmJb2e28qLXxT5kZxVUUoJt72EMzNGXB47Rxx5hw3q4YjS]
Listening on
 /ip4/75.157.120.249/tcp/60001/p2p/16Uiu2HAmQXuZmbjFWGagthwVsPFrc5ZrZ9c53qdUA45TWoZaokQn
Store enabled, but no store nodes configured. Choosing one at random from discovered peers
Connecting to storenode: 16Uiu2HAkvWiyFsgRhuJEb9JfjYxEkoHLgnUQmr1N5mKWnYjxYRVm
```
You will also see some historical messages  being fetched, again the content may be different on your end:

```
<Jul 26, 10:41> Bob: hi
<Jul 26, 10:41> Bob: hi
<Jun 29, 16:21> Alice: spam1
<Jun 29, 16:21> Alice: hiiii
<Jun 29, 16:21> Alice: hello
<Jun 29, 16:19> Bob: hi
<Jun 29, 16:19> Bob: hi
<Jun 29, 16:19> Alice: hi
<Jun 29, 16:15> b: hi
<Jun 29, 16:15> h: hi
...
```
Next, you see the following message:
```
rln-relay preparation is in progress ...
```
At this phase, your rln credentials are getting created and a transaction is sent to the contract.
It will take some time for the transaction to be finalized.
Once finalized, the registered  rln identity key, the rln identity commitment key, and the index of the registered credentials will be displayed as below.
In the snippet below, the rln identity key is not shown (replaced by a string of `x`s) for the security reason. 
But, you will see your own rln identity key.

```
your membership index is: 63
your rln identity key is: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
your rln identity commitment key is: 6c6598126ba10d1b70100893b76d7f8d7343eeb8f5ecfd48371b421c5aa6f012
```

Finally, the chat prompt `>>` will appear which means your chat2 client is ready.
Once you type a chat line and hit enter, you will see a message that indicates the epoch at which the message is sent e.g.,

```
>> Hi
--rln epoch: 165886530
<Jul 26, 12:55> Alice: Hi
```
The numerical value `165886530` indicates the epoch of the message `Hi`.
You will see a different value than `165886530` on your screen. 
If two messages sent by the same chat2 client happen to have the same RLN epoch value, then one of them will be detected as spam and won't be routed (by test fleets in this test setting).
At the time of this tutorial, the epoch duration is set to `10` seconds.
You can inspect the current epoch value by checking the following [constant variable](https://github.com/status-im/nim-waku/blob/21cac6d491a6d995a7a8ba84c85fecc7817b3d8b/waku/v2/protocol/waku_rln_relay/waku_rln_relay_types.nim#L119) in the nim-waku codebase.
Thus, if you send two messages less than `10` seconds apart, they are likely to get the same `rln epoch` values.

After sending a chat message, you may experience some delay before the next chat prompt appears. 
The reason is that under the hood a zero-knowledge proof is being generated and attached to your message.


Try to spam the network by violating the message rate limit i.e.,
sending more than one message per epoch. 
Your messages will be routed via test fleets that are running in rate-limited mode over the same content topic i.e., `/toy-chat/2/luzhou/proto`.
Your samp activity will be detected by them and your message will not reach the rest of the chat clients.
You can check this by running a second chat user and verifying that spam messages are filtered at the test fleets and won't be displayed. 
A sample test scenario is illustrated next.

Once you are done with the test, make sure you close all the chat2 clients by typing the `/exit` command.
```
>> /exit
quitting...
```

## How to reuse rln credentials

You may reuse your rln credentials as indicated below.
When running the chat2 client, amend the following options:

```
--rln-relay-membership-index:63 --rln-relay-id:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx --rln-relay-id-commitment:6c6598126ba10d1b70100893b76d7f8d7343eeb8f5ecfd48371b421c5aa6f012
```

Thus the execution command will look like:
```
./build/chat2  --fleet:test --content-topic:/toy-chat/2/luzhou/proto --rln-relay:true --rln-relay-dynamic:true --eth-mem-contract-address:0x4252105670fE33D2947e8EaD304969849E64f2a6  --eth-account-address:your_eth_account --eth-account-privatekey:your_eth_private_key  --eth-client-address:your_goerli_node  --ports-shift=1  --rln-relay-membership-index:63 --rln-relay-id:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx --rln-relay-id-commitment:6c6598126ba10d1b70100893b76d7f8d7343eeb8f5ecfd48371b421c5aa6f012

```
./build/chat2  --fleet:test --content-topic:/toy-chat/2/luzhou/proto --rln-relay:true --rln-relay-dynamic:true --eth-mem-contract-address:0x4252105670fE33D2947e8EaD304969849E64f2a6  --eth-account-address:your_eth_account --eth-account-privatekey:your_eth_private_key  --eth-client-address:your_goerli_node  --ports-shift=1  --rln-relay-membership-index:66 --rln-relay-id:dc308718989380f9b76823351fe8ea05c34898178bb9d2400b086a590e37621b --rln-relay-id-commitment:bd093cbf14fb933d53f596c33f98b3df83b7e9f7a1906cf4355fac712077cb28


# Sample test output
Below, is a sample test of running two chat clients.
Note that the values used for `eth-account-address`, `eth-account-privatekey`, and `eth-client-address` in the following snippets are junk and not valid.
In the following sample test, `Alice` sends 4 messages namely, `message1`, `message2`, `message3`, and `message4` though only three of them arrive at the `Bob` side. 
The two messages `message2` and `message3` have identical RLN epoch values, so, one of them will be discarded by the test fleets as a spam message. 
You can check this fact by looking at the `Bob` console, where `message3` is missing. 
The test fleets do not relay `message3` further, hence `Bob` never receives it.

Alice
``` 
./build/chat2  --fleet:test --content-topic:/toy-chat/2/luzhou/proto --rln-relay:true --rln-relay-dynamic:true --eth-mem-contract-address:0x4252105670fE33D2947e8EaD304969849E64f2a6  --eth-account-address:0x1234567890123456789012345678901234567890 --eth-account-privatekey:0x1234567890123456789012345678901234567890123456789012345678901234  --eth-client-address:wss://goerli.infura.io/ws/v3/12345678901234567890123456789012  --ports-shift=1 

Choose a nickname >> Alice
Welcome, Alice!
Connecting to test fleet using DNS discovery...
Discovered and connecting to @[16Uiu2HAkvWiyFsgRhuJEb9JfjYxEkoHLgnUQmr1N5mKWnYjxYRVm, 16Uiu2HAmPLe7Mzm8TsYUubgCAW1aJoeFScxrLj8ppHFivPo97bUZ, 16Uiu2HAmJb2e28qLXxT5kZxVUUoJt72EMzNGXB47Rxx5hw3q4YjS]
Listening on
 /ip4/75.157.120.249/tcp/60001/p2p/16Uiu2HAmH7XbkcdbA1CCs91r93HuwZHSdXppCNvJTDVvgGhuxyuG
Store enabled, but no store nodes configured. Choosing one at random from discovered peers
Connecting to storenode: 16Uiu2HAkvWiyFsgRhuJEb9JfjYxEkoHLgnUQmr1N5mKWnYjxYRVm
<Jul 26, 12:26> Alice: message3message3
<Jul 26, 12:26> Alice: message2
<Jul 26, 12:26> Alice: message1
<Jul 26, 10:41> Bob: hi
<Jul 26, 10:41> Bob: hi
<Jun 29, 16:21> Alice: spam1
<Jun 29, 16:21> Alice: hiiii
<Jun 29, 16:21> Alice: hello
<Jun 29, 16:19> Bob: hi
<Jun 29, 16:19> Bob: hi
<Jun 29, 16:19> Alice: hi
<Jun 29, 16:15> b: hi
<Jun 29, 16:15> h: hi
rln-relay preparation is in progress ...
your membership index is: 66
your rln identity key is: yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy
your rln identity commitment key is: bd093cbf14fb933d53f596c33f98b3df83b7e9f7a1906cf4355fac712077cb28
>> message1
--rln epoch: 165886591
<Jul 26, 13:05> Alice: message1
>> message2
--rln epoch: 165886592
<Jul 26, 13:05> Alice: message2
>> message3
--rln epoch: 165886592
<Jul 26, 13:05> Alice: message3
>> message4
--rln epoch: 165886593
<Jul 26, 13:05> Alice: message4
>> 
```

Bob
``` 
./build/chat2  --fleet:test --content-topic:/toy-chat/2/luzhou/proto --rln-relay:true --rln-relay-dynamic:true --eth-mem-contract-address:0x4252105670fE33D2947e8EaD304969849E64f2a6  --eth-account-address:0x1234567890123456789012345678901234567890 --eth-account-privatekey:0x1234567890123456789012345678901234567890123456789012345678901234  --eth-client-address:wss://goerli.infura.io/ws/v3/12345678901234567890123456789012  --ports-shift=2 

Choose a nickname >> Bob
Welcome, Bob!
Connecting to test fleet using DNS discovery...
Discovered and connecting to @[16Uiu2HAkvWiyFsgRhuJEb9JfjYxEkoHLgnUQmr1N5mKWnYjxYRVm, 16Uiu2HAmPLe7Mzm8TsYUubgCAW1aJoeFScxrLj8ppHFivPo97bUZ, 16Uiu2HAmJb2e28qLXxT5kZxVUUoJt72EMzNGXB47Rxx5hw3q4YjS]
Listening on
 /ip4/75.157.120.249/tcp/60002/p2p/16Uiu2HAmE7fPUWGJ7UFJ3p2a3RNiEtEvAWhpfUStcCDmVGhm4h4Z
Store enabled, but no store nodes configured. Choosing one at random from discovered peers
Connecting to storenode: 16Uiu2HAkvWiyFsgRhuJEb9JfjYxEkoHLgnUQmr1N5mKWnYjxYRVm
rln-relay preparation is in progress ...
your membership index is: 65
your rln identity key is: zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz
your rln identity commitment key is: d4961a7681521730bc7f9ade185c632b94b70624b2e87e21a97c07b83353f306
>> <Jul 26, 13:05> Alice: message1
>> <Jul 26, 13:05> Alice: message2
>> <Jul 26, 13:05> Alice: message4
>> 
```