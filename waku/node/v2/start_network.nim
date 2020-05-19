import
  strformat, os, osproc, net, confutils, strformat, chronicles, json, strutils,
  libp2p/multiaddress,
  libp2p/crypto/crypto,
  libp2p/protocols/protocol,
  libp2p/peerinfo

type
  NodeInfo* = object
    cmd: string
    address: string
    label: string

# TODO: initNodeCmd and get multiaddress here
# TODO: Then, setup a star network

# TODO: Create Node command, something like this:
# "build/wakunode --log-level:DEBUG --log-metrics --metrics-server --rpc  --waku-topic-interest:false --nodekey:e685079b7fa34dd35d3ffb2e40ab970360e94aa7dcc1262d36a8e2320a2c08ce --ports-shift:2 --discovery:off "
# What's equivalent of nodekey for libp2p? It is keypair.seckey in v1
# desc: "P2P node private key as hex.",
# Should be straightforward
# Ok cool so it is config.nim parseCmdArg, then use fromHex
proc initNodeCmd(): NodeInfo =
  let
    privKey = PrivateKey.random(Secp256k1)
    keys = KeyPair(seckey: privKey, pubkey: privKey.getKey())
    peerInfo = PeerInfo.init(privKey)
    # XXX
    DefaultAddr = "/ip4/127.0.0.1/tcp/55505"
    hostAddress = MultiAddress.init(DefaultAddr)

  peerInfo.addrs.add(hostAddress)

  result.cmd = "./build/foo"

# TODO: main and toHex fromHex private keys, then in config as nodekey
