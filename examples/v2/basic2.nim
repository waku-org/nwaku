# Here's an example of how you would start a Waku node, subscribe to topics, and
# publish to them

import confutils, chronicles, chronos

import libp2p/crypto/crypto
import libp2p/crypto/secp
import eth/keys

import ../../waku/node/v2/config
import ../../waku/node/v2/wakunode2

# Loads the config in `waku/node/v2/config.nim`
let conf = WakuNodeConf.load()

# Start the node
# Running this should give you output like this:
# INF Listening on tid=5719 full=/ip4/127.0.0.1/tcp/60000/p2p/16Uiu2HAmNiAqr1cwhyntotP9fiSDyBvfKtB4ZiaDsrkipSCoKCB4
run(conf)

# To do more operations on this node, we can do this in two ways:
# - We can use the Nim Node API, which is currently not exposed
# - We can use JSON RPC

# TODO Subscribe and publish to topic via Node API
# Requires https://github.com/status-im/nim-waku/issues/53

# TODO Show how to do this with JSON RPC
