# Building a local network of spam-protected chat2 clients 

This document is a tutorial on how to locally set up a small network of chat2 clients in a spam-protected mode using the waku-RLN-Relay protocol.
In the provided test scenario, you will set up three chat2 clients. 
For ease of explanation, we will refer to them as `Alice`, `Bob`, and `Carol`.
`Bob` and `Carol` are directly connected to `Alice` so that their message will be routed via `Alice`.
In this setting, if `Bob` or `Carol` attempts to spam the network by violating the message rate limit then `Alice` will detect their spamming activity, and does not relay the spam messages.
The message rate is one per epoch.
At the time of this tutorial, the epoch duration is set to `10` seconds.
You can inspect its current value by checking the following [constant variable](https://github.com/status-im/nim-waku/blob/21cac6d491a6d995a7a8ba84c85fecc7817b3d8b/waku/v2/protocol/waku_rln_relay/waku_rln_relay_types.nim#L119) in the nim-waku codebase.


# Set up
## Build chat2
First, build chat2 with the RLN flag set to true.

```
make chat2 RLN=true
```

## Create a local network of chat2 clients
Next, set up the following three chat2 clients in order.
As `Alice` is going to be the only connection point between `Bob` and `Carol`, you need to set it up first before `Bob` and `Carol`.

**Alice setup**:
Run the following command to set up the first chat2 client. In this command, the `rln-relay` flag is set to true to enable RLN-Relay protocol for the spam protection.
The `rln-relay-membership-index` is used to pick one RLN key out of the 100 available hardcoded RLN keys. 
We use the first RLN key of the list for `Alice` i.e., `--rln-relay-membership-index:1`.

```
./build/chat2 --staticnode:/ip4/127.0.0.1/tcp/60010/p2p/16Uiu2HAmKdCdP89q6CwLc6PeFDJnVR1EmM7fTgtphHiacSNBnuAz --content-topic:/toy-chat/2/luzhou/proto --ports-shift=1 --fleet:none --nodekey=f157b19b13e9ee818acfc9d3d7eec6b81f70c0a978dec19def261172acbe26e6 --rln-relay:true --rln-relay-membership-index:1

```

Next, you will be prompted with a message to choose a nickname, set it to `Alice`:
```
Choose a nickname >> Alice
```
Wait for the  chat prompt `>>` to appear.
Now your first chat2 client is ready.




**Bob setup**:
Set up the second chat2 client using the command below. Choose `Bob` as the nickname.
```
./build/chat2 --staticnode:/ip4/127.0.0.1/tcp/60001/p2p/16Uiu2HAkyTos6LeGrj1YJyA3WYzp9qKQGCsxbtvyoBRHSu9PCrQZ --content-topic:/toy-chat/2/luzhou/proto --ports-shift=2 --fleet:none --nodekey=9ab635854ffe8fed32b17d7ef38e0b2f354ca1f3283b7f78fb77227004d2cbe6 --rln-relay:true --rln-relay-membership-index:2 

Choose a nickname >> Bob
```

**Carol setup**:
Run the following command to set up the third chat2 client, and choose `Carol` as the nickname.
```
./build/chat2 --staticnode:/ip4/127.0.0.1/tcp/60001/p2p/16Uiu2HAkyTos6LeGrj1YJyA3WYzp9qKQGCsxbtvyoBRHSu9PCrQZ --content-topic:/toy-chat/2/luzhou/proto --ports-shift=3 --fleet:none --nodekey=0aa89d7f27300c9fb4e119acc225c8873a3bf96bbb4c82045c94934bcc6a6af8 --rln-relay:true --rln-relay-membership-index:3

Choose a nickname >> Carol

```

# Run the test
Now that the network is formed, you can start chatting.
For a better illustration of spam protection, use `Bob` and `Carol` clients for chatting and let `Alice` act only as a router.
Once you type a chat line and hit enter, you will see a message that indicates the epoch at which the message is sent e.g.,
```
>> Hi!
--rln epoch: 164495684
<Feb 15, 12:27> Bob: Hi!
```
The numerical value `164495684` indicates the epoch of the message `Hi!`.
You will see a different value than `164495684` on your screen. 
If two messages sent by the same chat2 client happen to have the same RLN epoch value, then one of them will be detected as spam and won't be routed (by Alice in this test setting).
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

In the following sample test, `Bob` sends three messages namely, `message1`, `message2`, and `message3`. 
The two messages `message2` and `message3` have identical RLN epoch value of `164504930`, so, one of them will be discarded by `Alice` as a spam message. 
You can check this fact by looking at the `Alice` console, where `A spam message is found and discarded : <Feb 16, 14:08> Bob: message3` is presented. 
`Alice` does not relay `message3` further, hence `Carol` never receives it.

Bob
```
./build/chat2 --staticnode:/ip4/127.0.0.1/tcp/60001/p2p/16Uiu2HAkyTos6LeGrj1YJyA3WYzp9qKQGCsxbtvyoBRHSu9PCrQZ --content-topic:/toy-chat/2/luzhou/proto --ports-shift=2 --fleet:none --nodekey=9ab635854ffe8fed32b17d7ef38e0b2f354ca1f3283b7f78fb77227004d2cbe6 --rln-relay:true --rln-relay-membership-index:2
Choose a nickname >> Bob
Welcome, Bob!
Connecting to nodes
Listening on
 /ip4/75.157.120.249/tcp/60002/p2p/16Uiu2HAmKdCdP89q6CwLc6PeFDJnVR1EmM7fTgtphHiacSNBnuAz
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
./build/chat2 --staticnode:/ip4/127.0.0.1/tcp/60010/p2p/16Uiu2HAmKdCdP89q6CwLc6PeFDJnVR1EmM7fTgtphHiacSNBnuAz --content-topic:/toy-chat/2/luzhou/proto --ports-shift=1 --fleet:none --nodekey=f157b19b13e9ee818acfc9d3d7eec6b81f70c0a978dec19def261172acbe26e6 --rln-relay:true --rln-relay-membership-index:1

Choose a nickname >> Alice
Welcome, Alice!
Connecting to nodes
Listening on
 /ip4/75.157.120.249/tcp/60001/p2p/16Uiu2HAkyTos6LeGrj1YJyA3WYzp9qKQGCsxbtvyoBRHSu9PCrQZ
>> <Feb 16, 14:08> Bob: message1
>> <Feb 16, 14:08> Bob: message2
>> A spam message is found and discarded : <Feb 16, 14:08> Bob: message3
<Feb 16, 14:15> Bob: message4
>> /exit
quitting...
```

Carol
```
./build/chat2 --staticnode:/ip4/127.0.0.1/tcp/60001/p2p/16Uiu2HAkyTos6LeGrj1YJyA3WYzp9qKQGCsxbtvyoBRHSu9PCrQZ --content-topic:/toy-chat/2/luzhou/proto --ports-shift=3 --fleet:none --nodekey=0aa89d7f27300c9fb4e119acc225c8873a3bf96bbb4c82045c94934bcc6a6af8 --rln-relay:true --rln-relay-membership-index:3
Choose a nickname >> Carol
Welcome, Carol!
Connecting to nodes
Listening on
 /ip4/75.157.120.249/tcp/60003/p2p/16Uiu2HAm1bEDWZqjxfYRvGo1UpjaejkenJVmMFMPMDmgWWGkREJu
>> <Feb 16, 14:08> Bob: message1
>> <Feb 16, 14:08> Bob: message2
>> <Feb 16, 14:15> Bob: message4
>> /exit
quitting...
```