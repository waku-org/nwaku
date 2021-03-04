# Using the `chat2` application

## Background

The `chat2` application is a basic command-line chat app using the [Waku v2 suite of protocols](https://specs.vac.dev/specs/waku/v2/waku-v2). It connects to a [fleet of test nodes](fleets.status.im) to provide end-to-end p2p chat capabilities. The Waku team is currently using this application for internal testing. If you want try our protocols, or join the dogfooding fun, follow the instructions below.

## Preparation

Ensure you have cloned the `nim-waku` repository and installed all prerequisites as per [these instructions](https://github.com/status-im/nim-waku).

Make the `chat2` target.

```
make chat2
```

## Basic application usage

To start the `chat2` application in its most basic form, run the following from the project directory

```
./build/chat2
```

You should be prompted to provide a nickname for the chat session.

```
Choose a nickname >>
```

After entering a nickname, the app will randomly select and connect to a peer from the test fleet.

```
No static peers configured. Choosing one at random from test fleet...
```

Wait for the chat prompt (`>>`) and chat away!

## Retrieving historical messages

The `chat2` application can retrieve historical chat messages from a node supporting and running the [Waku v2 store protocol](https://specs.vac.dev/specs/waku/v2/waku-store). Just specify the selected node's `multiaddr` as `storenode` when starting the app:

```
./build/chat2 --storenode:/ip4/134.209.139.210/tcp/30303/p2p/16Uiu2HAmPLe7Mzm8TsYUubgCAW1aJoeFScxrLj8ppHFivPo97bUZ
```

Alternatively, the `chat2` application will select a random `storenode` for you from the test fleet if the `store` option is set to `true` and `storenode` left unspecified.

```
./build/chat2 --store:true
```

> *NOTE: Currently (Mar 3, 2021) the only node in the test fleet that provides reliable store functionality is `/ip4/134.209.139.210/tcp/30303/p2p/16Uiu2HAmPLe7Mzm8TsYUubgCAW1aJoeFScxrLj8ppHFivPo97bUZ`. We're working on fixing this.*

## Specifying a static peer

In order to connect to a *specific* node as [`relay`](https://specs.vac.dev/specs/waku/v2/waku-relay) peer, define that node's `multiaddr` as a `staticnode` when starting the app:

```
./build/chat2 --staticnode:/ip4/134.209.139.210/tcp/30303/p2p/16Uiu2HAmPLe7Mzm8TsYUubgCAW1aJoeFScxrLj8ppHFivPo97bUZ
```

This will bypass the random peer selection process and connect to the specified node.

## In-chat options

| Command | Effect |
| --- | --- |
| `/help` | displays available in-chat commands |
| `/connect` | interactively connect to a new peer |
| `/nick` | change nickname for current chat session |