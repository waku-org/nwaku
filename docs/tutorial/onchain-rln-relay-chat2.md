This document is a tutorial on how to run chat2 in spam-protected/rate-limited mode using the waku-RLN-Relay protocol on a designated content topic  `/toy-chat/2/luzhou/proto`.

You will need 1) an Ethereum account with sufficient ethers on Goerli testnet as well as 2) a hosted node on Goerli testnet to be able to run the tests. 
We have  also dedicated a few sections at the end of this tutorial on how to get those.


In this tutorial, we will test the on-chain waku-rln-relay.
The `on-chain` refers to the fact the rln membership group management is now moderated through a contract deployed on Ethereum Goerli testnet.

You will run a chat2 client with waku-rln-relay mounted in on-chain mode and on a certain content topic `/toy-chat/2/luzhou/proto`.
Being mounted in on-chain mode means that your rln credentials i.e., identity commitment will be registered to the rln membership group contract deployed on the Ethereum Goerli testnet. 
In the background, your chat2 client is constantly listening to the contract and keeps itself updated with the latest state of the group.

You will connect your chat2 client to waku2 test fleets.
Test fleet nodes route your messages as well as filter spam messages.
In specific, they run waku-rln-relay on the `/toy-chat/2/luzhou/proto` content topic which is the content topic used in this tutorial for the chat application.

In this setting, you should try to spam the network by violating the message rate limit i.e.,
sending more than one message per epoch. 
At the time of this tutorial, the epoch duration is set to `10` seconds.
You can inspect the current epoch value by checking the following [constant variable](https://github.com/status-im/nim-waku/blob/21cac6d491a6d995a7a8ba84c85fecc7817b3d8b/waku/v2/protocol/waku_rln_relay/waku_rln_relay_types.nim#L119) in the nim-waku codebase.
Your messages will be routed via test fleets that are running in rate-limited mode over the same content topic i.e., `/toy-chat/2/luzhou/proto`.
Your samp activity will be detected by them and your message will not reach the rest of chat clients.
You can check this by running a second chat user and verifying that spam messages are filtered at the test fleets. 

# Set up chat2 app in spam-protected mode


