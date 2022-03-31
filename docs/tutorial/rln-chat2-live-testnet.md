# Communicating with waku2 test fleets using chat2 application in spam-protected mode

This document is a tutorial on how to run chat2 in spam-protected/rate-limited mode using the waku-RLN-Relay protocol on a designated content topic  `/toy-chat/2/luzhou/proto`.
You will connect your chat2 client to waku2 test fleets.
Note that test fleets will not filter spam messages, they merely route messages.
Spam detection takes place at the chat2 users end.
In this setting, you should try to spam the network by violating the message rate limit i.e.,
sending more than one message per epoch. 
At the time of this tutorial, the epoch duration is set to `10` seconds.
You can inspect the current epoch value by checking the following [constant variable](https://github.com/status-im/nim-waku/blob/21cac6d491a6d995a7a8ba84c85fecc7817b3d8b/waku/v2/protocol/waku_rln_relay/waku_rln_relay_types.nim#L119) in the nim-waku codebase.
Your messages will be routed via test fleets and will arrive at other live chat2 clients that are running in rate-limited mode over the same content topic i.e., `/toy-chat/2/luzhou/proto`.
Your samp activity will be detected by them and a proper message will be shown on their console.  

# Set up
## Build chat2
First, build chat2 with the RLN flag set to true.

```
make chat2 RLN=true
```

## Setup a chat2 node in rate-limited mode
Run the following command to set up your chat2 client. 

```
./build/chat2 --content-topic:/toy-chat/2/luzhou/proto --ports-shift=1 --fleet:test --rln-relay:true --rln-relay-membership-index:your_index

```
In this command
- the `rln-relay` flag is set to true to enable RLN-Relay protocol for spam protection.
- the `rln-relay-membership-index` is used to pick one RLN key out of the 100 available hardcoded RLN keys. 
You can pass your index using this command `--rln-relay-membership-index: your_index` e.g., `--rln-relay-membership-index:19` .
Please use the index assigned to you in the dogfooding coordination phase.
If you pick an index at random you may end up using the same key-pair as someone else, hence your messaging rate will be shared with that person(s).


Next, choose your nickname:
```
Choose a nickname >> your_nick_name
```
Wait for the chat prompt `>>` to appear.
Now your chat2 client is ready.

You may set up more than one chat client,
just make sure that you increment the `--ports-shift` value for each new client you set up e.g., `--ports-shift=2`.

# Run the test
Now that you have set up your client, start chatting.
Once you type a chat line and hit enter, you will see a message that indicates the epoch at which the message is sent e.g.,
```
>> Hi!
--rln epoch: 164495684
<Feb 15, 12:27> Bob: Hi!
```
The numerical value `164495684` indicates the epoch of the message `Hi!`.
You will see a different value than `164495684` on your screen. 
If two messages sent by the same chat2 client happen to have the same RLN epoch value, then one of them will be detected as spam by the receiving chat2 clients.
At the time of this tutorial, the epoch duration is set to `10` seconds.
Thus, if you send two messages less than `10` seconds apart, they are likely to get the same `rln epoch` values.

After sending a chat message, you may experience some delay before the next chat prompt appears. 
The reason is that under the hood a zero-knowledge proof is being generated and attached to your message.

Once you are done with the test, make sure you close all the chat2 clients by typing `/exit` command.
```
>> /exit
quitting...
```

# Sample test output

In the following sample test, two chat2 clients are set up, namely `Alice` and `Bob`.
`Bob` sends three messages i.e., `message1`, `message2`, and `message3` to the test fleets. 
Test fleets will route the messages to their connections including `Alice`.
The two messages `message2` and `message3` have an identical RLN epoch value of `164504930`, so, one of them will be detected as a spam message by `Alice`. 
You can check this fact by looking at the `Alice` console, where `A spam message is found and discarded : <Feb 16, 14:08> Bob: message3` is presented. 


Bob
```
./build/chat2  --content-topic:/toy-chat/2/luzhou/proto --ports-shift=2 --fleet:test  --rln-relay:true --rln-relay-membership-index:2
Choose a nickname >> Bob
Welcome, Bob!
Connecting to test fleet using DNS discovery...
Discovered and connecting to @[16Uiu2HAmPLe7Mzm8TsYUubgCAW1aJoeFScxrLj8ppHFivPo97bUZ, 16Uiu2HAkvWiyFsgRhuJEb9JfjYxEkoHLgnUQmr1N5mKWnYjxYRVm, 16Uiu2HAmJb2e28qLXxT5kZxVUUoJt72EMzNGXB47Rxx5hw3q4YjS]
Listening on
 /ip4/75.157.120.249/tcp/60002/p2p/16Uiu2HAmKdCdP89q6CwLc6PeFDJnVR1EmM7fTgtphHiacSNBnuAz
Store enabled, but no store nodes configured. Choosing one at random from discovered peers
Connecting to storenode: 16Uiu2HAmPLe7Mzm8TsYUubgCAW1aJoeFScxrLj8ppHFivPo97bUZ
>> message1
--rln epoch: 164504929
<Feb 16, 14:08> Bob: message1
>> message2
--rln epoch: 164504930
<Feb 16, 14:08> Bob: message2
>> message3
--rln epoch: 164504930
<Feb 16, 14:08> Bob: message3
>> message4
--rln epoch: 164504973
<Feb 16, 14:15> Bob: message4
>> /exit
quitting...
```


Alice
```
./build/chat2 --content-topic:/toy-chat/2/luzhou/proto --ports-shift=1 --fleet:test  --rln-relay:true --rln-relay-membership-index:1

Choose a nickname >> Alice
Welcome, Alice!
Connecting to test fleet using DNS discovery...
Discovered and connecting to @[16Uiu2HAmPLe7Mzm8TsYUubgCAW1aJoeFScxrLj8ppHFivPo97bUZ, 16Uiu2HAkvWiyFsgRhuJEb9JfjYxEkoHLgnUQmr1N5mKWnYjxYRVm, 16Uiu2HAmJb2e28qLXxT5kZxVUUoJt72EMzNGXB47Rxx5hw3q4YjS]
Listening on
 /ip4/75.157.120.249/tcp/60001/p2p/16Uiu2HAkyTos6LeGrj1YJyA3WYzp9qKQGCsxbtvyoBRHSu9PCrQZ
Store enabled, but no store nodes configured. Choosing one at random from discovered peers
Connecting to storenode: 16Uiu2HAmPLe7Mzm8TsYUubgCAW1aJoeFScxrLj8ppHFivPo97bUZ
>> <Feb 16, 14:08> Bob: message1
>> <Feb 16, 14:08> Bob: message2
>> A spam message is found and discarded : <Feb 16, 14:08> Bob: message3
<Feb 16, 14:15> Bob: message4
>> /exit
quitting...
```

# Trouble shooting

## compilation error: found possibly newer version of crate


If running `make chat2 RLN=true` yields a compile error like this

```
error[E0460]: found possibly newer version of crate `std` which `sapling_crypto_ce` depends on
 --> src/circuit/polynomial.rs:1:5
  |
1 | use sapling_crypto::bellman::pairing::ff::{Field, PrimeField, PrimeFieldRepr};
```

run

`make cleanrln` before running `make chat2 RLN=true` again.
