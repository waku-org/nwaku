# Spam-protected chat2 application with on-chain group management

This document is a tutorial on how to run the chat2 application in the spam-protected mode using the Waku-RLN-Relay protocol and with dynamic/on-chain group management.
In the on-chain/dynamic group management, the state of the group members i.e., their identity commitment keys is moderated via a membership smart contract deployed on the Goerli network which is one of the Ethereum test-nets.
Members can be dynamically added to the group and the group size can grow up to 2^20 members.
This differs from the prior test scenarios in which the RLN group was static and the set of members' keys was hardcoded and fixed.


## Prerequisites 
To complete this tutorial, you will need 1) an account with at least `0.001` ethers on the Goerli test net and 2) a hosted node on the Goerli testnet. 
In case you are not familiar with either of these two steps, you may follow the following tutorial to fulfill the [prerequisites of running on-chain spam-protected chat2](./pre-requisites-of-running-on-chain-spam-protected-chat2.md).
Note that the required `0.001` ethers correspond to the registration fee, 
however, you still need to have more funds in your account to cover the cost of the transaction gas fee.



## Overview
Figure 1 provides an overview of the interaction of the chat2 clients with the test fleets and the membership contract. 
At a high level, when a chat2 client is run with Waku-RLN-Relay mounted in on-chain mode, it creates an RLN credential (i.e., an identity key and an identity commitment key) and 
sends a transaction to the membership contract to register the corresponding membership identity commitment key.
This transaction will also transfer `0.001` Ethers to the contract as a membership fee.
This amount plus the transaction fee will be deducted from the supplied Goerli account. 
Once the transaction is mined and the registration is successful, the registered credential will get displayed on the console of your chat2 client.
You may copy the displayed RLN credential and reuse them for the future execution of the chat2 application.
Proper instructions in this regard is provided in the following [section](#how-to-persist-and-reuse-rln-credential).
If you choose not to reuse the same credential, then for each execution, a new registration will take place and more funds will get deducted from your Goerli account.
Under the hood, the chat2 client constantly listens to the membership contract and keeps itself updated with the latest state of the group.

In the following test setting, the chat2 clients are to be connected to the Waku test fleets as their first hop. 
The test fleets will act as routers and are also set to run Waku-RLN-Relay over the same pubsub topic and content topic as chat2 clients i.e., the default pubsub topic of `/waku/2/default-waku/proto` and the content topic of `/toy-chat/2/luzhou/proto`. 
Spam messages published on the said combination of topics will be caught by the test fleet nodes and will not be routed.
Note that spam protection does not rely on the presence of the test fleets.
In fact, all the chat2 clients are also capable of catching and dropping spam messages if they receive any.
You can test it by connecting two chat2 clients (running Waku-RLN-Relay) directly to each other and see if they can spot each other's spam activities.

 ![](./imgs/rln-relay-chat2-overview.png)
 Figure 1.

# Set up
## Build chat2
First, build chat2 with the RLN flag set to true.

```bash
make chat2 RLN=true
```

## Set up a chat2 client

Run the following command to set up your chat2 client. 

```bash
./build/chat2 --fleet:test --content-topic:/toy-chat/2/luzhou/proto --rln-relay:true --rln-relay-dynamic:true --rln-relay-eth-contract-address:0x4252105670fe33d2947e8ead304969849e64f2a6 --rln-relay-eth-account-address:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx --rln-relay-eth-account-private-key:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx --rln-relay-eth-client-address:xxxx --ports-shift=1 
```

In this command
- the `--fleet:test` indicates that the chat2 app gets connected to the test fleets.
- the `toy-chat/2/luzhou/proto` passed to the `content-topic` option indicates the content topic on which the chat2 application is going to run.
- the `rln-relay` flag is set to `true` to enable the Waku-RLN-Relay protocol for spam protection.
- the `--rln-relay-dynamic` flag is set to `true` to enable the on-chain mode of Waku-RLN-Relay protocol with dynamic group management.
- the `--rln-relay-eth-contract-address` option gets the address of the membership contract.
 The current address of the contract is `0x4252105670fe33d2947e8ead304969849e64f2a6`.
 You may check the state of the contract on the [Goerli testnet](https://goerli.etherscan.io/address/0x4252105670fe33d2947e8ead304969849e64f2a6).
- the `rln-relay-eth-account-address` option is for your account address on the Goerli testnet.
 It is a hex string of length 40 (not sensitive to the `0x` prefix). 
- the `rln-relay-eth-account-private-key` option is for your account private key on the Goerli testnet. 
 It is made up of 64 hex characters (not sensitive to the `0x` prefix).
- the `rln-relay-eth-client-address` is the WebSocket address of the hosted node on the Goerli testnet. 
 You need to replace the `xxxx` with the actual node's address.

For the last three config options i.e., `rln-relay-eth-account-address`, `rln-relay-eth-account-private-key`, and `rln-relay-eth-client-address`, if you do not know how to obtain those, you may use the following tutorial on the [prerequisites of running on-chain spam-protected chat2](./pre-requisites-of-running-on-chain-spam-protected-chat2.md).

You may set up more than one chat client,
just make sure that you increment the `--ports-shift` value for each new client you set up e.g., `--ports-shift=2`.

Once you run the command, you are asked to choose your nickname:
```
Choose a nickname >> Alice
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
You will  also see some historical messages being fetched, again the content may be different on your end:

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
At this phase, your RLN credential is being created and a transaction is being sent to the membership smart contract.
It will take some time for the transaction to be finalized.
Once finalized, a link to the transaction on the Goerli network will be shown i.e., 
```
You are registered to the rln membership contract, find details of your registration transaction in https://goerli.etherscan.io/tx/0xxxx 
```
Note that you will see the actual transaction hash instead of `0xxxx`.
Also, the registered RLN identity key, the RLN identity commitment key, and the index of the registered credential will be displayed as given below.
Note that in the figure, the RLN identity key is not shown for security reasons (replaced by a string of `x`s).
But, you will see your RLN identity key.

```
your membership index is: xx
your RLN identity key is: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
your RLN identity commitment key is: 6c6598126ba10d1b70100893b76d7f8d7343eeb8f5ecfd48371b421c5aa6f012
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
Your messages will be routed via test fleets that are running in spam-protected mode over the same content topic i.e., `/toy-chat/2/luzhou/proto` as your chat client.
Your spam activity will be detected by them and your message will not reach the rest of the chat clients.
You can check this by running a second chat user and verifying that spam messages are not displayed as they are filtered by the test fleets.
Furthermore, the chat client will prompt you with the following warning message indicating that the message rate is being violated:
```
⚠️ message rate violation! you are spamming the network!
```
A sample test scenario is illustrated in the [Sample test output section](#sample-test-output).

Once you are done with the test, make sure you close all the chat2 clients by typing the `/exit` command.
```
>> /exit
quitting...
```

## How to persist and reuse RLN credential

You may pass the `rln-relay-cred-path` config option to specify a path for 1) persisting RLN credentials and 2) retrieving persisted RLN credentials.  
RLN credential is persisted in the `rlnCredentials.txt` file under the specified path.
If this file does not already exist under the supplied path, then a new credential is generated and persisted in the `rlnCredentials.txt` file.
Otherwise, the chat client does not generate a new credential and will use, instead, the persisted RLN credential.

```bash
./build/chat2  --fleet:test --content-topic:/toy-chat/2/luzhou/proto --rln-relay:true --rln-relay-dynamic:true --rln-relay-eth-contract-address:0x4252105670fe33d2947e8ead304969849e64f2a6  --rln-relay-eth-account-address:your_eth_account --rln-relay-eth-account-private-key:your_eth_private_key  --rln-relay-eth-client-address:your_goerli_node  --ports-shift=1  --rln-relay-cred-path:./
```

Note: If you are reusing credentials, you can omit the `rln-relay-eth-account-address` and `rln-relay-eth-account-private-key` flags

Therefore, the command to start chat2 would be -

```bash
./build/chat2  --fleet:test --content-topic:/toy-chat/2/luzhou/proto --rln-relay:true --rln-relay-dynamic:true --rln-relay-eth-contract-address:0x4252105670fe33d2947e8ead304969849e64f2a6 --rln-relay-eth-client-address:your_goerli_node  --ports-shift=1  --rln-relay-cred-path:./
```

# Sample test output
In this section, a sample test of running two chat clients is provided.
Note that the values used for `rln-relay-eth-account-address`, `rln-relay-eth-account-private-key`, and `rln-relay-eth-client-address` in the following code snippets are junk and not valid.

The two chat clients namely `Alice` and `Bob` are connected to the test fleets.
`Alice` sends 4 messages i.e., `message1`, `message2`, `message3`, and `message4`.
However, only three of them reach `Bob`. 
This is because the two messages `message2` and `message3` have identical RLN epoch values, so, one of them gets discarded by the test fleets as a spam message. 
The test fleets do not relay `message3` further, hence `Bob` never receives it.
You can check this fact by looking at `Bob`'s console, where `message3` is missing. 


**Alice**
```bash
./build/chat2 --fleet:test --content-topic:/toy-chat/2/luzhou/proto --rln-relay:true --rln-relay-dynamic:true --rln-relay-eth-contract-address:0x4252105670fe33d2947e8ead304969849e64f2a6 --rln-relay-eth-account-address:0x1234567890123456789012345678901234567890 --rln-relay-eth-account-private-key:0x1234567890123456789012345678901234567890123456789012345678901234 --rln-relay-eth-client-address:wss://goerli.infura.io/ws/v3/12345678901234567890123456789012 --ports-shift=1 
```

```
Choose a nickname >> Alice
Welcome, Alice!
Connecting to test fleet using DNS discovery...
Discovered and connecting to @[16Uiu2HAkvWiyFsgRhuJEb9JfjYxEkoHLgnUQmr1N5mKWnYjxYRVm, 16Uiu2HAmPLe7Mzm8TsYUubgCAW1aJoeFScxrLj8ppHFivPo97bUZ, 16Uiu2HAmJb2e28qLXxT5kZxVUUoJt72EMzNGXB47Rxx5hw3q4YjS]
Listening on
 /ip4/75.157.120.249/tcp/60001/p2p/16Uiu2HAmH7XbkcdbA1CCs91r93HuwZHSdXppCNvJTDVvgGhuxyuG
Store enabled, but no store nodes configured. Choosing one at random from discovered peers
Connecting to storenode: 16Uiu2HAkvWiyFsgRhuJEb9JfjYxEkoHLgnUQmr1N5mKWnYjxYRVm
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
You are registered to the rln membership contract, find details of your registration transaction in https://goerli.etherscan.io/tx/0xxxx 
your membership index is: xx
your rln identity key is: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
your rln identity commitment key is: bd093cbf14fb933d53f596c33f98b3df83b7e9f7a1906cf4355fac712077cb28
>> message1
--rln epoch: 165886591
<Jul 26, 13:05> Alice: message1
>> message2
--rln epoch: 165886592
<Jul 26, 13:05> Alice: message2
>> message3
--rln epoch: 165886592 ⚠️ message rate violation! you are spamming the network!
<Jul 26, 13:05> Alice: message3
>> message4
--rln epoch: 165886593
<Jul 26, 13:05> Alice: message4
>> 
```

**Bob**
```bash
./build/chat2 --fleet:test --content-topic:/toy-chat/2/luzhou/proto --rln-relay:true --rln-relay-dynamic:true --rln-relay-eth-contract-address:0x4252105670fe33d2947e8ead304969849e64f2a6 --rln-relay-eth-account-address:0x1234567890123456789012345678901234567890 --rln-relay-eth-account-private-key:0x1234567890123456789012345678901234567890123456789012345678901234 --rln-relay-eth-client-address:wss://goerli.infura.io/ws/v3/12345678901234567890123456789012 --ports-shift=2 
```

```
Choose a nickname >> Bob
Welcome, Bob!
Connecting to test fleet using DNS discovery...
Discovered and connecting to @[16Uiu2HAkvWiyFsgRhuJEb9JfjYxEkoHLgnUQmr1N5mKWnYjxYRVm, 16Uiu2HAmPLe7Mzm8TsYUubgCAW1aJoeFScxrLj8ppHFivPo97bUZ, 16Uiu2HAmJb2e28qLXxT5kZxVUUoJt72EMzNGXB47Rxx5hw3q4YjS]
Listening on
 /ip4/75.157.120.249/tcp/60002/p2p/16Uiu2HAmE7fPUWGJ7UFJ3p2a3RNiEtEvAWhpfUStcCDmVGhm4h4Z
Store enabled, but no store nodes configured. Choosing one at random from discovered peers
Connecting to storenode: 16Uiu2HAkvWiyFsgRhuJEb9JfjYxEkoHLgnUQmr1N5mKWnYjxYRVm
rln-relay preparation is in progress ...
You are registered to the rln membership contract, find details of your registration transaction in https://goerli.etherscan.io/tx/0xxxx 
your membership index is: xx
your rln identity key is: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
your rln identity commitment key is: d4961a7681521730bc7f9ade185c632b94b70624b2e87e21a97c07b83353f306
>> <Jul 26, 13:05> Alice: message1
>> <Jul 26, 13:05> Alice: message2
>> <Jul 26, 13:05> Alice: message4
>> 
```