# Waku v1 example
## Introduction
This is a basic Waku v1 example to show the Waku v1 API usage.

It can be run as a single node, in which case it will just post and receive its
own messages.

Or multiple nodes can be started and can connect to each other, so that
messages can be passed around.

## How to build
```sh
make example1
```

## How to run
### Single node
```sh
# Lauch example node
./build/example
```

Messages will be posted and received.

### Multiple nodes

```sh
# Launch first example node
./build/example
```

Now look for an `INFO` log containing the enode address, e.g.:
`enode://26..5b@0.0.0.0:30303` (but with full address)

Copy the full enode string of the first node and start the second
node with that enode string as staticnode config option:
```sh
# Launch second example node, providing the enode address of the first node
./build/example --staticnode:enode://26..5b@0.0.0.0:30303 --ports-shift:1
```

Now both nodes will receive also messages from each other.
